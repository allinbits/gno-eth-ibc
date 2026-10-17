// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ReentrancyGuardTransient } from "@openzeppelin-contracts/utils/ReentrancyGuardTransient.sol";
import { AccessManagedUpgradeable } from "@openzeppelin-upgradeable/access/manager/AccessManagedUpgradeable.sol";

import { IIBCStore } from "@eureka/interfaces/IIBCStore.sol";
import { IICS02Client } from "@eureka/interfaces/IICS02Client.sol";
import { ILightClient } from "@eureka/interfaces/ILightClient.sol";
import { ILightClientMsgs } from "@eureka/msgs/ILightClientMsgs.sol";
import { IGnoLightClientStatus } from "../interfaces/IGnoLightClientStatus.sol";
import { IIBCSenderCallbacks } from "@eureka/interfaces/IIBCSenderCallbacks.sol";
import { IIBCAppCallbacks } from "@eureka/msgs/IIBCAppCallbacks.sol";
import { IICS26RouterMsgs } from "@eureka/msgs/IICS26RouterMsgs.sol";
import { IICS20TransferMsgs } from "@eureka/msgs/IICS20TransferMsgs.sol";
import { ICS20Lib } from "@eureka/utils/ICS20Lib.sol";
import { ICS24Host } from "@eureka/utils/ICS24Host.sol";

import { IGnoICS20ControlsTypes } from "../interfaces/IGnoICS20Controls.sol";
import { LeakyBucket } from "../lib/LeakyBucket.sol";
import { GnoTransferStorage } from "./GnoTransferStorage.sol";

/// @title The evidence functions of GnoICS20Transfer's controls (ADR pr6375 §7.12, §7.13)
/// @notice Runs only by delegatecall, from GnoICS20Reconcile's fallback (itself reached through the controls), in the
/// transfer proxy's storage and under its AccessManager: proven destination outcomes, receive records, incident
/// views and sender notifications.
contract GnoICS20Evidence is IGnoICS20ControlsTypes, ReentrancyGuardTransient, AccessManagedUpgradeable {
    address private immutable _self;

    error NotDelegated();

    constructor() {
        _self = address(this);
    }

    /// @notice The controls version this module implements (kind 7 checks it on the module and through the proxy).
    function gnoEvidenceModuleVersion() external pure returns (uint256) {
        return 1;
    }

    /// @notice The address this module recorded as its own at construction (kind 7 requires it to be the module's
    /// address: a module whose recorded address is another, such as the proxy's, would refuse every delegated call).
    function gnoSelf() external view returns (address) {
        return _self;
    }

    modifier delegated() {
        if (address(this) == _self) revert NotDelegated();
        _;
    }

    function _g() private pure returns (GnoTransferStorage.Layout storage) {
        return GnoTransferStorage.layout();
    }

    /// @notice See IGnoICS20Controls.
    function gnoReceipt(IICS26RouterMsgs.Packet calldata packet) public pure returns (bytes32) {
        return sha256(
            abi.encodePacked(
                uint8(3), packet.sequence, sha256(bytes(packet.sourceClient)), ICS24Host.packetCommitmentBytes32(packet)
            )
        );
    }

    /// @notice See IGnoICS20Controls.
    function proveOutcome(
        IICS26RouterMsgs.Packet calldata packet,
        OutcomeProof calldata proof
    )
        external
        delegated
        nonReentrant
        returns (Proven proven)
    {
        GnoTransferStorage.Layout storage g = _g();
        SendRecord storage rec = g.records[keccak256(bytes(packet.sourceClient))][packet.sequence];
        require(g.retired[packet.sourceClient], GnoBadProof());
        // through the route's replacement: its current client, active, and that client's counterparty prefix
        string memory current = g.currentOf[GnoTransferStorage.routeKey(packet.sourceClient)];
        IICS02Client router = IICS02Client(GnoTransferStorage.ics20Router());
        ILightClient lc = ILightClient(GnoTransferStorage.activeClient(packet.sourceClient));
        // final once proven, unless its verifier is no longer the active replacement (the outcome is then void)
        require(
            address(lc) != address(0) && rec.commitment != bytes32(0)
                && ICS24Host.packetCommitmentBytes32(packet) == rec.commitment && rec.settlement == 0
                && (rec.proven == Proven.None
                    || rec.provenBy != address(lc)
                    || rec.provenGen != g.routes[GnoTransferStorage.routeHash(packet.sourceClient)].verifierGen),
            GnoBadProof()
        );
        bytes memory receiptPath = ICS24Host.packetReceiptCommitmentPathCalldata(packet.destClient, packet.sequence);
        if (proof.receipt == bytes32(0)) {
            uint256 time = lc.verifyNonMembership(
                ILightClientMsgs.MsgVerifyNonMembership(
                    proof.receiptProof,
                    proof.proofHeight,
                    ICS24Host.prefixedPath(router.getCounterparty(current).merklePrefix, receiptPath)
                )
            );
            // not received, and past its timeout: never receivable
            require(time >= packet.timeoutTimestamp, GnoBadProof());
            proven = Proven.Refundable;
        } else {
            lc.verifyMembership(
                ILightClientMsgs.MsgVerifyMembership(
                    proof.receiptProof,
                    proof.proofHeight,
                    ICS24Host.prefixedPath(router.getCounterparty(current).merklePrefix, receiptPath),
                    abi.encodePacked(proof.receipt)
                )
            );
            if (proof.receipt != gnoReceipt(packet)) {
                proven = Proven.Collision;
            } else {
                bytes[] memory acks = new bytes[](1);
                acks[0] = proof.ack;
                lc.verifyMembership(
                    ILightClientMsgs.MsgVerifyMembership(
                        proof.ackProof,
                        proof.proofHeight,
                        ICS24Host.prefixedPath(
                            router.getCounterparty(current).merklePrefix,
                            ICS24Host.packetAcknowledgementCommitmentPathCalldata(packet.destClient, packet.sequence)
                        ),
                        abi.encodePacked(ICS24Host.packetAcknowledgementCommitmentBytes32(acks))
                    )
                );
                proven = keccak256(proof.ack) == ICS24Host.KECCAK256_UNIVERSAL_ERROR_ACK
                    ? Proven.Refundable
                    : Proven.Delivered;
            }
        }
        uint256 reservedBefore = GnoTransferStorage.reservation(rec);
        rec.proven = proven;
        rec.provenBy = address(lc);
        if (proven == Proven.Delivered) {
            g.provenAck[keccak256(bytes(packet.sourceClient))][packet.sequence] = keccak256(proof.ack);
        }
        bytes32 route = GnoTransferStorage.routeHash(packet.sourceClient);
        rec.provenGen = g.routes[route].verifierGen;
        // a hidden refund proven owed is reserved now; a new proof of another outcome releases it
        GnoTransferStorage.syncReserve(route, rec, reservedBefore);
        emit GnoOutcomeProven(packet.sourceClient, packet.sequence, proven);
    }

    /// @notice See IGnoICS20Controls.
    function voidOutcome(string calldata clientId, uint64 sequence) external delegated nonReentrant {
        GnoTransferStorage.Layout storage g = _g();
        SendRecord storage rec = g.records[keccak256(bytes(clientId))][sequence];
        bytes32 route = GnoTransferStorage.routeHash(clientId);
        // void: proven, unsettled, and its verifier no longer the route's active one under the same generation
        require(
            rec.proven != Proven.None && rec.settlement == 0
                && (rec.provenBy != GnoTransferStorage.activeClient(clientId)
                    || rec.provenGen != g.routes[route].verifierGen),
            GnoBadProof()
        );
        uint256 reservedBefore = GnoTransferStorage.reservation(rec);
        rec.proven = Proven.None;
        rec.provenBy = address(0);
        GnoTransferStorage.syncReserve(route, rec, reservedBefore);
        emit GnoOutcomeProven(clientId, sequence, Proven.None);
    }

    /// @notice See IGnoICS20Controls.
    function incidents(string calldata clientId)
        external
        view
        delegated
        returns (Incident[] memory, uint64 resolvedUpTo, uint64 pending)
    {
        GnoTransferStorage.Route storage r = _g().routes[GnoTransferStorage.routeHash(clientId)];
        Incident[] memory list = r.incidents;
        for (uint256 i = 0; i < list.length; i++) {
            list[i].status = GnoTransferStorage.incidentStatus(r, i);
        }
        return (list, r.resolvedUpTo, r.pendingIncidents);
    }

    /// @notice See IGnoICS20Controls.
    function clientRecon(string calldata clientId)
        external
        view
        delegated
        returns (uint64, uint32, uint64, uint64, uint64)
    {
        GnoTransferStorage.ClientRecon storage c = _g().clients[keccak256(bytes(clientId))];
        return (c.open, c.incident, c.suspectStart, c.suspectOpen, uint64(c.processed.length));
    }

    /// @notice See IGnoICS20Controls.
    function lossBooked(
        string calldata clientId,
        uint64 sequence,
        uint8 direction
    )
        external
        view
        delegated
        returns (bool)
    {
        return _g().lossBooked[keccak256(abi.encode(keccak256(bytes(clientId)), sequence, direction))];
    }

    /// @notice See IGnoICS20Controls.
    function receiveRecord(
        string calldata clientId,
        uint64 sequence
    )
        external
        view
        delegated
        returns (address, uint256)
    {
        uint256 r = _g().receives[keccak256(bytes(clientId))][sequence];
        return (address(uint160(r)), r >> 160);
    }

    /// @notice See IGnoICS20Controls.
    function notifySettled(
        IICS26RouterMsgs.Packet calldata packet,
        bytes calldata ack,
        uint256 gasBudget
    )
        external
        delegated
        nonReentrant
        returns (bool)
    {
        bytes32 h = keccak256(bytes(packet.sourceClient));
        SendRecord storage rec = _g().records[h][packet.sequence];
        (uint8 transport, uint8 terminal) = GnoTransferStorage.noticeKinds(rec);
        // a success the transport's ack announced but never delivered (the sender refused it): the settlement's
        // proven ack replaces it, which may differ from the transport's (a forged ack of a delivered packet). Exactly
        // once: delivering either marks the transport's notification done
        bool replace = terminal == 1 && transport == 1 && _g().notices[h][packet.sequence] != bytes32(0)
            && !_g().noticeDone[h][packet.sequence];
        // the settlement's terminal outcome, when the transport brought another kind (or none): a refund once paid in
        // full, or a success with the ack proven for it
        require(
            rec.commitment != bytes32(0) && ICS24Host.packetCommitmentBytes32(packet) == rec.commitment && terminal != 0
                && (terminal != transport || replace)
                && (terminal == 2
                        ? rec.payment == Payment.Claimed
                        : keccak256(ack) == _g().provenAck[h][packet.sequence]),
            GnoNoNotification(packet.sourceClient, packet.sequence)
        );
        bytes memory call = terminal == 2
            ? abi.encodeCall(
                IIBCSenderCallbacks.onTimeoutPacket,
                (IIBCAppCallbacks.OnTimeoutPacketCallback(
                        packet.sourceClient, packet.destClient, packet.sequence, packet.payloads[0], msg.sender
                    ))
            )
            : abi.encodeCall(
                IIBCSenderCallbacks.onAckPacket,
                (
                    true,
                    IIBCAppCallbacks.OnAcknowledgementPacketCallback(
                        packet.sourceClient, packet.destClient, packet.sequence, packet.payloads[0], ack, msg.sender
                    )
                )
            );
        bool ok = GnoTransferStorage.deliverSettled(rec.sender, call, packet.sourceClient, packet.sequence, gasBudget);
        if (ok && replace) _g().noticeDone[h][packet.sequence] = true;
        return ok;
    }

    /// @notice See IGnoICS20Controls.
    function retryNotification(
        string calldata clientId,
        uint64 sequence,
        bytes calldata call,
        uint256 gasBudget
    )
        external
        delegated
        nonReentrant
        returns (bool)
    {
        bytes32 h = keccak256(bytes(clientId));
        SendRecord storage rec = _g().records[h][sequence];
        (uint8 transport, uint8 terminal) = GnoTransferStorage.noticeKinds(rec);
        if (transport == 1 && terminal == 1) {
            // settled as delivered: only the proven ack is announced (a forged transport ack never is)
            require(
                bytes4(call) == IIBCSenderCallbacks.onAckPacket.selector
                    && _ackOf(call[4:]) == _g().provenAck[h][sequence],
                GnoNoNotification(clientId, sequence)
            );
        }
        return GnoTransferStorage.retryNotice(rec, clientId, sequence, call, gasBudget);
    }

    /// @notice The ack hash of an encoded `onAckPacket(bool, OnAcknowledgementPacketCallback)` argument list.
    function _ackOf(bytes calldata args) private pure returns (bytes32) {
        (, IIBCAppCallbacks.OnAcknowledgementPacketCallback memory cb) =
            abi.decode(args, (bool, IIBCAppCallbacks.OnAcknowledgementPacketCallback));
        return keccak256(cb.acknowledgement);
    }
}
