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
/// proxy), in the proxy's storage and under its AccessManager: parked refunds, settlement by decision, reopening,
/// and the backfill of records for packets sent before the fork was installed.
contract GnoICS20Reconcile is IGnoICS20ControlsTypes, ReentrancyGuardTransient, AccessManagedUpgradeable {
    address private immutable _self;

    error NotDelegated();

    constructor() {
        _self = address(this);
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
        // the meter charged first (checks-effects-interactions); a failed payment reverts it all
        got = rec.settlement == 1 ? remaining : LeakyBucket.chargeUpTo(t.refunded, t.limits.refundCap, remaining, now_);
        if (got == 0) return 0;
        require(
            GnoTransferStorage.tryPayRefund(rec, got, route, reservedBefore, false), GnoRefundFailed(clientId, sequence)
        );
        emit GnoRefundPaid(clientId, sequence, rec.token, rec.sender, got);
        if (got == remaining) {
            rec.payment = Payment.Claimed;
            GnoTransferStorage.closeRecord(rec, route);
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
        // sealed while a reopening accepts the deficits: the loss ledger it walks never changes behind it
        require(!g.routes[route].reopening, GnoRouteReopening(clientId));
        // an outcome counts only while the client that proved it is still the route's active replacement, under
        // the same generation; checked again for every outcome consumed and after the last payment, since a
        // payment runs token code that could freeze or swap it (any change rolls the whole batch back)
        address active = _activeClient(clientId);
        uint64 gen = g.routes[route].verifierGen;
        for (uint256 i = 0; i < items.length; i++) {
            SettleItem calldata it = items[i];
            if (it.action == 5) {
                _bookForgedReceive(g, route, clientHash, clientId, it, i);
                continue;
            }
            SendRecord storage rec = g.records[clientHash][it.sequence];
            // a record (authenticated: written by the send or backfilled), settled at most once
            require(
                rec.commitment != bytes32(0) && rec.settlement == 0 && active != address(0) && rec.provenBy == active
                    && rec.provenGen == gen && _activeClient(clientId) == active && g.routes[route].verifierGen == gen,
                GnoBadSettlement(i)
            );
            // a record processed in the suspected compromise interval: one fewer to settle
            if (rec.processedBlock != 0 && rec.processedIndex >= g.routes[route].suspectStart) {
                --g.routes[route].suspectOpen;
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
                    if (GnoTransferStorage.tryPayRefund(rec, left, route, reservedBefore, true)) {
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
                require(
                    (action == 3 || owed) && rec.refunded == 0 && rec.proven == Proven.Delivered, GnoBadSettlement(i)
                );
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
                if (it.amount != 0) _bookLoss(g, route, clientId, rec.token, it.sequence, it.amount);
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
            GnoTransferStorage.closeRecord(rec, route);
            GnoTransferStorage.syncReserve(route, rec, reservedBefore);
            emit GnoSettled(clientId, it.sequence, action, it.amount);
        }
        require(
            _activeClient(clientId) == active && g.routes[route].verifierGen == gen, GnoBadSettlement(type(uint256).max)
        );
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
        _bookLoss(g, route, clientId, token, it.sequence, amount);
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
        uint256 amount
    )
        private
    {
        GnoTransferStorage.Route storage r = g.routes[route];
        if (g.losses[route][token] == 0) r.lossTokens.push(token);
        g.losses[route][token] += amount;
        string memory key = GnoTransferStorage.routeKey(clientId);
        emit GnoLossRecorded(key, token, sequence, amount);
        if (!r.closed) {
            r.closed = true;
            r.lossClosed = true;
            emit GnoRouteClosedForLoss(key);
        }
    }

    /// @notice A queued or parked refund rejected by reconciliation: never paid, its notification dropped.
    function _reject(SendRecord storage rec, string calldata clientId, uint64 sequence) private {
        rec.payment = Payment.Rejected;
        GnoTransferStorage.dropNotice(clientId, sequence);
        emit GnoRefundRejected(clientId, sequence);
    }

    /// @notice Deficits accepted per call: kind 13's first batch, and at most this per `continueReopen` call.
    uint256 private constant REOPEN_BATCH = 16;

    /// @notice See IGnoICS20Controls.
    function reopenRoute(string calldata clientId) external delegated restricted nonReentrant {
        GnoTransferStorage.Route storage r = _route(clientId);
        require(r.closed && !r.reopening, GnoNotClosed(clientId));
        // every record of the retired ids reconciled first: no outstanding packet, no refund owed (a route closed
        // again for a late loss was reconciled when it first reopened: its open records are the live client's)
        require(r.lossClosed || r.openRecords == 0, GnoRecordsOpen(clientId, r.openRecords));
        // and every ack or timeout processed in the suspected compromise interval settled
        require(r.suspectOpen == 0, GnoSuspectUnsettled(clientId, r.suspectOpen));
        r.reopening = true;
        r.deficitCursor = 0;
        // every record processed so far is reconciled: a later replacement's interval starts above them
        r.processedFloor = uint64(r.processed.length);
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
            r.reopening = false;
            // every prerequisite again before the route opens: nothing opened or became suspect meanwhile
            if ((!r.lossClosed && r.openRecords != 0) || r.suspectOpen != 0) {
                emit GnoReopenAborted(key);
                return;
            }
            r.closed = false;
            r.lossClosed = false;
            emit GnoRouteReopened(key);
        }
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
        ILightClient lc = ILightClient(_activeClient(packet.sourceClient));
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

    /// @notice The route's replacement client if active (neither frozen nor expired), else zero.
    function _activeClient(string memory clientId) private view returns (address) {
        string memory current = _g().currentOf[GnoTransferStorage.routeKey(clientId)];
        address lc = address(IICS02Client(GnoTransferStorage.ics20Router()).getClient(current));
        if (IGnoLightClientStatus(lc).isFrozen() || IGnoLightClientStatus(lc).isExpired()) return address(0);
        return lc;
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
