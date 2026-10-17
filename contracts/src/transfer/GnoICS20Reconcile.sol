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

/// @title The reconciliation functions of GnoICS20Transfer's controls (ADR pr6375 §5.4 kinds 12 and 13, §7.12,
/// §7.13)
/// @notice Runs only by delegatecall, from GnoICS20Controls' fallback (itself delegatecalled by the transfer
/// proxy), in the proxy's storage and under its AccessManager: parked refunds, settlement by decision and
/// reopening.
contract GnoICS20Reconcile is IGnoICS20ControlsTypes, ReentrancyGuardTransient, AccessManagedUpgradeable {
    address private immutable _self;
    /// @notice GnoICS20Evidence: the proofs, views and notifications, served by this contract's fallback.
    address public immutable EVIDENCE;

    error NotDelegated();

    constructor(address evidence) {
        require(evidence.code.length != 0, GnoBadModule());
        _self = address(this);
        EVIDENCE = evidence;
    }

    /// @notice Serves the evidence functions from GnoICS20Evidence, in the transfer proxy's storage.
    // solhint-disable-next-line no-complex-fallback
    fallback() external {
        address e = EVIDENCE;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), e, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch ok
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    /// @notice The controls version this module implements (kind 7 checks it on the module and through the proxy).
    function gnoReconcileModuleVersion() external pure returns (uint256) {
        return 1;
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
        uint64 sequence,
        uint256 gasBudget
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
        // the meter charged first (checks-effects-interactions); a failed payment reverts it all
        got = rec.settlement == 1 ? remaining : LeakyBucket.chargeUpTo(t.refunded, t.limits.refundCap, remaining, now_);
        if (got == 0) return 0;
        require(
            GnoTransferStorage.tryPayRefund(rec, got, route, reservedBefore, gasBudget),
            GnoRefundFailed(clientId, sequence)
        );
        emit GnoRefundPaid(clientId, sequence, rec.token, rec.sender, got);
        if (got == remaining) {
            rec.payment = Payment.Claimed;
            GnoTransferStorage.closeRecord(rec, keccak256(bytes(clientId)));
            emit GnoOutcomeRecorded(clientId, sequence, rec.outcome, Payment.Claimed);
            GnoTransferStorage.releaseNotice(clientId, sequence);
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
        // sealed while its incident reopens: the records kind 13 found settled never change behind it
        uint32 inc = g.clients[clientHash].incident;
        require(
            inc != 0 && GnoTransferStorage.incidentStatus(g.routes[route], inc - 1) != GnoTransferStorage.REOPENING,
            GnoRouteReopening(clientId)
        );
        // an outcome counts only while the client that proved it is still the route's active replacement, under
        // the same generation; checked again for every outcome consumed and after the last payment, since a
        // payment runs token code that could freeze or swap it (any change rolls the whole batch back)
        address active = GnoTransferStorage.activeClient(clientId);
        uint64 gen = g.routes[route].verifierGen;
        for (uint256 i = 0; i < items.length; i++) {
            if (items[i].action == 5) _bookForgedReceive(g, route, clientHash, clientId, items[i], i);
            else _settleRecord(g, route, clientHash, clientId, items[i], i, active, gen);
        }
        require(
            GnoTransferStorage.activeClient(clientId) == active && g.routes[route].verifierGen == gen,
            GnoBadSettlement(type(uint256).max)
        );
    }

    /// @notice One kind 12 item on a send record (actions 1 to 4).
    function _settleRecord(
        GnoTransferStorage.Layout storage g,
        bytes32 route,
        bytes32 clientHash,
        string calldata clientId,
        SettleItem calldata it,
        uint256 i,
        address active,
        uint64 gen
    )
        private
    {
        SendRecord storage rec = g.records[clientHash][it.sequence];
        // a record (written by the send), settled at most once
        require(
            rec.commitment != bytes32(0) && rec.settlement == 0 && active != address(0) && rec.provenBy == active
                && rec.provenGen == gen && GnoTransferStorage.activeClient(clientId) == active
                && g.routes[route].verifierGen == gen,
            GnoBadSettlement(i)
        );
        // a record processed in the suspected compromise interval: one fewer to settle
        GnoTransferStorage.ClientRecon storage c = g.clients[clientHash];
        if (rec.processedBlock != 0 && rec.processedIndex >= c.suspectStart) {
            bool had = GnoTransferStorage.hasWork(c);
            --c.suspectOpen;
            GnoTransferStorage.noteWork(c, had);
        }
        uint8 action = it.action;
        bool owed = rec.payment == Payment.Queued || rec.payment == Payment.Parked;
        uint256 reservedBefore = GnoTransferStorage.reservation(rec);
        if (action == 1) {
            // a genuine refund: its whole remainder, never cut short (ADR §7.9); zero when it was already paid in
            // full, which only settles the record
            uint256 left = rec.amount - rec.refunded;
            // proven not delivered: an error ack, never receivable, or another packet at its sequence
            require(
                it.amount == left && (rec.proven == Proven.Refundable || rec.proven == Proven.Collision),
                GnoBadSettlement(i)
            );
            rec.settlement = 1;
            if (left != 0) {
                if (GnoTransferStorage.tryPayRefund(rec, left, route, reservedBefore, 0)) {
                    rec.payment = Payment.Claimed;
                    emit GnoRefundPaid(clientId, it.sequence, rec.token, rec.sender, left);
                    // the notification is due: anyone delivers it by retryNotification
                    GnoTransferStorage.releaseNotice(clientId, it.sequence);
                } else {
                    rec.payment = Payment.Parked;
                    emit GnoRefundParked(clientId, it.sequence, rec.token, left);
                }
            }
        } else if (action == 2 || action == 3) {
            // a refund already (partly) paid can only be settled as forged (action 4, which books the loss) or
            // genuine (action 1)
            require((action == 3 || owed) && rec.refunded == 0 && rec.proven == Proven.Delivered, GnoBadSettlement(i));
            rec.settlement = action;
            if (owed) _reject(rec, clientId, it.sequence);
        } else if (action == 4) {
            // a forged refund (of a packet that was delivered): its unpaid remainder is rejected and what was
            // already paid is the loss, at once
            require(
                (rec.outcome == Outcome.ErrorAck || rec.outcome == Outcome.Timeout) && it.amount == rec.refunded
                    && rec.proven == Proven.Delivered,
                GnoBadSettlement(i)
            );
            rec.settlement = 4;
            if (owed) _reject(rec, clientId, it.sequence);
            if (it.amount != 0) _bookLoss(g, route, clientId, rec.token, it.sequence, it.amount, OUTBOUND);
        } else {
            revert GnoBadSettlement(i);
        }
        // one terminal notification per record: a settlement deciding another kind than the transport's
        // supersedes the transport's (never delivered after); `notifySettled` delivers the settlement's
        (uint8 transport, uint8 terminal) = GnoTransferStorage.noticeKinds(rec);
        if (transport != terminal) {
            if (transport != 0) GnoTransferStorage.dropNotice(clientId, it.sequence);
            if (terminal == 1 || rec.payment == Payment.Claimed) emit GnoNotificationDue(clientId, it.sequence);
        }
        GnoTransferStorage.closeRecord(rec, clientHash);
        GnoTransferStorage.syncReserve(route, rec, reservedBefore);
        emit GnoSettled(clientId, it.sequence, action, it.amount);
    }

    /// @notice Kind 12 action 5: a forged receive at an inbound sequence of the retired client, whose release or
    /// mint is booked as a loss once, for exactly the amount the receive recorded.
    function _bookForgedReceive(
        GnoTransferStorage.Layout storage g,
        bytes32 route,
        bytes32 clientHash,
        string calldata clientId,
        SettleItem calldata it,
        uint256 i
    )
        private
    {
        uint256 r = g.receives[clientHash][it.sequence];
        uint256 amount = r >> 160;
        require(amount != 0 && amount == it.amount, GnoBadSettlement(i));
        address token = address(uint160(r));
        g.receives[clientHash][it.sequence] = uint160(token); // booked: never again
        _bookLoss(g, route, clientId, token, it.sequence, amount, INBOUND);
        emit GnoSettled(clientId, it.sequence, 5, amount);
    }

    /// @notice Books a loss of the route. A loss found after the route reopened closes it again at once: it opens
    /// only by a new kind 13, which accepts the loss as a deficit (ADR §7.9), never with a loss left unaccepted.
    function _bookLoss(
        GnoTransferStorage.Layout storage g,
        bytes32 route,
        string calldata clientId,
        address token,
        uint64 sequence,
        uint256 amount,
        uint8 direction
    )
        private
    {
        // one canonical identity per packet, whatever the booking path: (client id, sequence, direction)
        bytes32 id = keccak256(abi.encode(keccak256(bytes(clientId)), sequence, direction));
        require(!g.lossBooked[id], GnoLossBooked(clientId, sequence, direction));
        g.lossBooked[id] = true;
        GnoTransferStorage.Route storage r = g.routes[route];
        // the loss ledger never changes while a reopening walks it
        require(!r.reopening, GnoRouteReopening(clientId));
        if (g.losses[route][token] == 0) r.lossTokens.push(token);
        g.losses[route][token] += amount;
        string memory key = GnoTransferStorage.routeKey(clientId);
        emit GnoLossRecorded(key, token, sequence, amount);
        if (!r.closed) {
            // a late loss: an incident of its own, which needs only its loss accepted by a new kind 13
            r.closed = true;
            r.incidents.push(Incident(GnoTransferStorage.LATE_LOSS, GnoTransferStorage.OPEN, bytes32(0), 0));
            emit GnoRouteClosedForLoss(key);
        }
    }

    /// @notice A queued or parked refund rejected by reconciliation: never paid, its notification dropped.
    function _reject(SendRecord storage rec, string calldata clientId, uint64 sequence) private {
        rec.payment = Payment.Rejected;
        GnoTransferStorage.dropNotice(clientId, sequence);
        emit GnoRefundRejected(clientId, sequence);
    }

    /// @notice A loss's direction: a send's forged refund (action 4), or a forged receive (action 5).
    uint8 private constant OUTBOUND = 1;
    uint8 private constant INBOUND = 2;

    /// @notice Deficits accepted per call: kind 13's first batch, and at most this per `continueReopen` call.
    uint256 private constant REOPEN_BATCH = 16;

    /// @notice See IGnoICS20Controls.
    function reopenRoute(string calldata clientId) external delegated restricted nonReentrant {
        GnoTransferStorage.Route storage r = _route(clientId);
        require(r.closed && !r.reopening, GnoNotClosed(clientId));
        // every unresolved incident settled (constant work: the count is kept as records settle): its client's
        // records reconciled (no outstanding packet, no refund owed, no unsettled suspect record); a late loss needs
        // only its loss accepted
        require(r.pendingIncidents == 0, GnoIncidentsPending(clientId, r.pendingIncidents));
        r.reopening = true;
        r.reopenUpTo = uint64(r.incidents.length);
        r.deficitCursor = 0;
        _acceptDeficits(r, clientId, REOPEN_BATCH);
    }

    /// @notice See IGnoICS20Controls.
    function continueReopen(string calldata clientId, uint256 n) external delegated nonReentrant {
        GnoTransferStorage.Route storage r = _route(clientId);
        require(r.reopening, GnoNotClosed(clientId));
        _acceptDeficits(r, clientId, n > REOPEN_BATCH ? REOPEN_BATCH : n);
    }

    /// @notice Accepts as deficits up to `n` tokens' losses not yet accepted (ADR §7.9: a loss not recapitalized),
    /// and opens the route when none is left.
    function _acceptDeficits(GnoTransferStorage.Route storage r, string calldata clientId, uint256 n) private {
        string memory key = GnoTransferStorage.routeKey(clientId);
        bytes32 route = keccak256(bytes(key));
        GnoTransferStorage.Layout storage g = _g();
        uint256 i = r.deficitCursor;
        uint256 end = r.lossTokens.length;
        if (end > i + n) end = i + n;
        for (; i < end; i++) {
            address token = r.lossTokens[i];
            uint256 open_ = g.losses[route][token] - g.acceptedDeficit[route][token];
            if (open_ != 0) {
                g.acceptedDeficit[route][token] += open_;
                emit GnoDeficitAccepted(key, token, open_);
            }
        }
        r.deficitCursor = uint64(i);
        if (i == r.lossTokens.length) {
            // every reopening incident again before the route opens: nothing opened or became suspect meanwhile
            if (r.pendingIncidents != 0) {
                GnoTransferStorage.abortReopening(r, key);
                return;
            }
            r.resolvedUpTo = r.reopenUpTo;
            r.reopening = false;
            r.closed = false;
            emit GnoRouteReopened(key);
        }
    }
}
