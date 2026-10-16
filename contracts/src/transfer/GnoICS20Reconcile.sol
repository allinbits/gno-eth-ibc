// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ReentrancyGuardTransient } from "@openzeppelin-contracts/utils/ReentrancyGuardTransient.sol";
import { AccessManagedUpgradeable } from "@openzeppelin-upgradeable/access/manager/AccessManagedUpgradeable.sol";

import { IIBCStore } from "@eureka/interfaces/IIBCStore.sol";
import { IICS26RouterMsgs } from "@eureka/msgs/IICS26RouterMsgs.sol";
import { IICS20TransferMsgs } from "@eureka/msgs/IICS20TransferMsgs.sol";
import { ICS20Lib } from "@eureka/utils/ICS20Lib.sol";
import { ICS24Host } from "@eureka/utils/ICS24Host.sol";

import { IGnoICS20ControlsTypes } from "../interfaces/IGnoICS20Controls.sol";
import { LeakyBucket } from "../lib/LeakyBucket.sol";
import { GnoTransferStorage } from "./GnoTransferStorage.sol";

/// @title The reconciliation functions of GnoICS20Transfer's controls (ADR pr6375 §5.4 kinds 12 and 13, §7.12,
/// §7.13)
/// @notice Runs only by delegatecall, from GnoICS20Controls' fallback (itself delegatecalled by the transfer
/// proxy), in the proxy's storage and under its AccessManager: parked refunds, settlement by decision, reopening,
/// and the backfill of records for packets sent before the fork was installed.
contract GnoICS20Reconcile is IGnoICS20ControlsTypes, ReentrancyGuardTransient, AccessManagedUpgradeable {
    address private immutable _self;

    error NotDelegated();

    constructor() {
        _self = address(this);
    }

    modifier delegated() {
        if (address(this) == _self) revert NotDelegated();
        _;
    }

    function _g() private pure returns (GnoTransferStorage.Layout storage) {
        return GnoTransferStorage.layout();
    }

    function _route(string calldata clientId) private view returns (GnoTransferStorage.Route storage) {
        return _g().routes[GnoTransferStorage.routeHash(clientId)];
    }

    /// @notice A route whose refunds may be paid: not closed and not under a refunds hold.
    function _openRoute(string calldata clientId) private view returns (bytes32 route) {
        route = GnoTransferStorage.routeHash(clientId);
        require(!_g().routes[route].closed, GnoRouteClosed(clientId));
        require(!GnoTransferStorage.refundsHeld(route), GnoRefundsHeld(clientId));
    }

    /// @notice See IGnoICS20Controls.
    function claimParked(
        string calldata clientId,
        uint64 sequence
    )
        external
        delegated
        nonReentrant
        returns (uint256 got)
    {
        GnoTransferStorage.Layout storage g = _g();
        SendRecord storage rec = g.records[keccak256(bytes(clientId))][sequence];
        require(rec.payment == Payment.Parked, GnoNotParked(clientId, sequence));
        bytes32 route = _openRoute(clientId);
        GnoTransferStorage.TokenControls storage t = g.tokens[route][rec.token];
        uint64 now_ = uint64(block.timestamp);
        uint256 reservedBefore = GnoTransferStorage.reservation(rec);
        uint256 remaining = GnoTransferStorage.refundable(rec);
        // a refund kind 12 decided is not metered; one from an ack or timeout is
        got = rec.settlement == 1 ? remaining : LeakyBucket.available(t.refunded, t.limits.refundCap, now_);
        if (got > remaining) got = remaining;
        if (got == 0) return 0;
        require(GnoTransferStorage.tryPayRefund(rec, got), GnoRefundFailed(clientId, sequence));
        if (rec.settlement != 1) LeakyBucket.charge(t.refunded, t.limits.refundCap, got, now_);
        emit GnoRefundPaid(clientId, sequence, rec.token, rec.sender, got);
        if (got == remaining) {
            rec.payment = Payment.Claimed;
            GnoTransferStorage.closeRecord(rec, route);
            emit GnoOutcomeRecorded(clientId, sequence, rec.outcome, Payment.Claimed);
            GnoTransferStorage.releaseNotice(rec, clientId, sequence);
        }
        GnoTransferStorage.syncReserve(route, rec, reservedBefore);
    }

    // -------------------------------------------------------------------------------------- reconciliation --

    /// @notice See IGnoICS20Controls.
    function settleRecords(
        string calldata clientId,
        SettleItem[] calldata items
    )
        external
        delegated
        restricted
        nonReentrant
    {
        GnoTransferStorage.Layout storage g = _g();
        require(g.retired[clientId], GnoBadSettlement(type(uint256).max));
        bytes32 clientHash = keccak256(bytes(clientId));
        bytes32 route = GnoTransferStorage.routeHash(clientId);
        for (uint256 i = 0; i < items.length; i++) {
            SettleItem calldata it = items[i];
            SendRecord storage rec = g.records[clientHash][it.sequence];
            // a record (authenticated: written by the send or backfilled), settled at most once
            require(rec.commitment != bytes32(0) && rec.settlement == 0, GnoBadSettlement(i));
            uint8 action = it.action;
            bool owed = rec.payment == Payment.Queued || rec.payment == Payment.Parked;
            uint256 reservedBefore = GnoTransferStorage.reservation(rec);
            if (action == 1) {
                // a genuine refund: its whole remainder, never cut short (ADR §7.9); zero when it was already paid in
                // full, which only settles the record
                uint256 left = rec.amount - rec.refunded;
                require(it.amount == left, GnoBadSettlement(i));
                rec.settlement = 1;
                if (left != 0) {
                    if (GnoTransferStorage.tryPayRefund(rec, left)) {
                        rec.payment = Payment.Claimed;
                        emit GnoRefundPaid(clientId, it.sequence, rec.token, rec.sender, left);
                        GnoTransferStorage.releaseNotice(rec, clientId, it.sequence);
                    } else {
                        rec.payment = Payment.Parked;
                        emit GnoRefundParked(clientId, it.sequence, rec.token, left);
                    }
                }
            } else if (action == 2 || action == 3) {
                // a refund already (partly) paid can only be settled as forged (action 4, which books the loss) or
                // genuine (action 1)
                require((action == 3 || owed) && rec.refunded == 0, GnoBadSettlement(i));
                rec.settlement = action;
                if (owed) _reject(g, rec, clientHash, clientId, it.sequence);
            } else if (action == 4) {
                // a forged refund (of a packet that was delivered): its unpaid remainder is rejected and what was
                // already paid is the loss, at once
                require(
                    (rec.outcome == Outcome.ErrorAck || rec.outcome == Outcome.Timeout) && it.amount == rec.refunded,
                    GnoBadSettlement(i)
                );
                rec.settlement = 4;
                if (owed) _reject(g, rec, clientHash, clientId, it.sequence);
                if (it.amount != 0) {
                    if (g.losses[route][rec.token] == 0) g.routes[route].lossTokens.push(rec.token);
                    g.losses[route][rec.token] += it.amount;
                    emit GnoLossRecorded(GnoTransferStorage.routeKey(clientId), rec.token, it.sequence, it.amount);
                }
            } else {
                revert GnoBadSettlement(i);
            }
            GnoTransferStorage.closeRecord(rec, route);
            GnoTransferStorage.syncReserve(route, rec, reservedBefore);
            emit GnoSettled(clientId, it.sequence, action, it.amount);
        }
    }

    /// @notice A queued or parked refund rejected by reconciliation: never paid, its notification dropped.
    function _reject(
        GnoTransferStorage.Layout storage g,
        SendRecord storage rec,
        bytes32 clientHash,
        string calldata clientId,
        uint64 sequence
    )
        private
    {
        rec.payment = Payment.Rejected;
        delete g.notices[clientHash][sequence];
        emit GnoRefundRejected(clientId, sequence);
    }

    /// @notice See IGnoICS20Controls.
    function reopenRoute(string calldata clientId) external delegated restricted {
        GnoTransferStorage.Route storage r = _route(clientId);
        require(r.closed, GnoNotClosed(clientId));
        // every record of the retired ids reconciled first: no outstanding packet, no refund owed
        require(r.openRecords == 0, GnoRecordsOpen(clientId, r.openRecords));
        string memory key = GnoTransferStorage.routeKey(clientId);
        bytes32 route = keccak256(bytes(key));
        GnoTransferStorage.Layout storage g = _g();
        // a loss not recapitalized is accepted as the route's deficit by this decision (ADR §7.9)
        for (uint256 i = 0; i < r.lossTokens.length; i++) {
            address token = r.lossTokens[i];
            uint256 open_ = g.losses[route][token] - g.acceptedDeficit[route][token];
            if (open_ != 0) {
                g.acceptedDeficit[route][token] += open_;
                emit GnoDeficitAccepted(key, token, open_);
            }
        }
        r.closed = false;
        emit GnoRouteReopened(key);
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
        emit GnoBackfilled(packet.sourceClient, packet.sequence, commitment);
    }

    /// @notice See IGnoICS20Controls.
    function retryNotification(string calldata clientId, uint64 sequence)
        external
        delegated
        nonReentrant
        returns (bool)
    {
        SendRecord storage rec = _g().records[keccak256(bytes(clientId))][sequence];
        return GnoTransferStorage.retryNotice(rec, clientId, sequence);
    }
}
