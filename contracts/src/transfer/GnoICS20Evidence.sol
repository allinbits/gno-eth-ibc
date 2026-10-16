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
/// transfer proxy's storage and under its AccessManager: backfilled records, proven destination outcomes, receive
/// records and sender notifications.
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

    modifier delegated() {
        if (address(this) == _self) revert NotDelegated();
        _;
    }

    function _g() private pure returns (GnoTransferStorage.Layout storage) {
        return GnoTransferStorage.layout();
    }

    /// @notice See IGnoICS20Controls.
    function backfill(IICS26RouterMsgs.Packet calldata packet) external delegated nonReentrant {
        require(
            packet.payloads.length == 1
                && keccak256(bytes(packet.payloads[0].sourcePort)) == ICS20Lib.KECCAK256_DEFAULT_PORT_ID,
            GnoBadBackfill()
        );
        bytes32 commitment = ICS24Host.packetCommitmentBytes32(packet);
        address router = GnoTransferStorage.ics20Router();
        require(
            IIBCStore(router).getCommitment(ICS24Host.packetCommitmentKeyCalldata(packet.sourceClient, packet.sequence))
                == commitment,
            GnoBadBackfill()
        );
        SendRecord storage rec = _g().records[keccak256(bytes(packet.sourceClient))][packet.sequence];
        require(rec.commitment == bytes32(0), GnoBadBackfill());
        IICS20TransferMsgs.FungibleTokenPacketData memory data =
            abi.decode(packet.payloads[0].value, (IICS20TransferMsgs.FungibleTokenPacketData));
        // the refund target, derived as the refund path derives it
        bool burned = ICS20Lib.hasPrefix(
            bytes(data.denom), abi.encodePacked(ICS20Lib.DEFAULT_PORT_ID, "/", packet.sourceClient, "/")
        );
        address token = GnoTransferStorage.ics20Registered(string(GnoTransferStorage.toRouteDenom(bytes(data.denom))));
        if (token == address(0)) {
            require(!burned, GnoBadBackfill());
            token = ICS20Lib.mustHexStringToAddress(data.denom);
        }
        rec.commitment = commitment;
        rec.sender = ICS20Lib.mustHexStringToAddress(data.sender);
        rec.token = token;
        rec.escrow = GnoTransferStorage.ics20Escrow(GnoTransferStorage.routeKey(packet.sourceClient));
        rec.timeoutTimestamp = packet.timeoutTimestamp;
        rec.sendBlock = uint64(block.number);
        rec.burned = burned;
        rec.amount = data.amount;
        rec.legacy = true;
        GnoTransferStorage.openRecord(rec, GnoTransferStorage.routeHash(packet.sourceClient));
        GnoTransferStorage.syncReserve(GnoTransferStorage.routeHash(packet.sourceClient), rec, 0);
        emit GnoBackfilled(packet.sourceClient, packet.sequence, commitment);
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
        rec.proven = proven;
        rec.provenBy = address(lc);
        if (proven == Proven.Delivered) {
            g.provenAck[keccak256(bytes(packet.sourceClient))][packet.sequence] = keccak256(proof.ack);
        }
        rec.provenGen = g.routes[GnoTransferStorage.routeHash(packet.sourceClient)].verifierGen;
        emit GnoOutcomeProven(packet.sourceClient, packet.sequence, proven);
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
        // the settlement's terminal outcome, when the transport brought another kind (or none): a refund once paid in
        // full, or a success with the ack proven for it
        require(
            rec.commitment != bytes32(0) && ICS24Host.packetCommitmentBytes32(packet) == rec.commitment && terminal != 0
                && terminal != transport
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
        return GnoTransferStorage.deliverSettled(rec.sender, call, packet.sourceClient, packet.sequence, gasBudget);
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
        SendRecord storage rec = _g().records[keccak256(bytes(clientId))][sequence];
        return GnoTransferStorage.retryNotice(rec, clientId, sequence, call, gasBudget);
    }
}
