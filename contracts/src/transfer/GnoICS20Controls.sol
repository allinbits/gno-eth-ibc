// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ReentrancyGuardTransient } from "@openzeppelin-contracts/utils/ReentrancyGuardTransient.sol";
import { AccessManagedUpgradeable } from "@openzeppelin-upgradeable/access/manager/AccessManagedUpgradeable.sol";

import { IICS02Client } from "@eureka/interfaces/IICS02Client.sol";
import { IIBCStore } from "@eureka/interfaces/IIBCStore.sol";
import { IICS26RouterMsgs } from "@eureka/msgs/IICS26RouterMsgs.sol";
import { IICS20TransferMsgs } from "@eureka/msgs/IICS20TransferMsgs.sol";
import { ICS20Lib } from "@eureka/utils/ICS20Lib.sol";
import { ICS24Host } from "@eureka/utils/ICS24Host.sol";
import { IGnoICS20Controls } from "../interfaces/IGnoICS20Controls.sol";
import { IGnoLightClientStatus } from "../interfaces/IGnoLightClientStatus.sol";
import { IGuardians } from "../interfaces/IGuardians.sol";
import { Guardians } from "../lib/Guardians.sol";
import { LeakyBucket } from "../lib/LeakyBucket.sol";
import { GnoTransferStorage } from "./GnoTransferStorage.sol";

/// @title The governance, guardian, claim and view functions of GnoICS20Transfer's controls
/// @notice Runs only by delegatecall from GnoICS20Transfer's fallback (EIP-170 keeps the two apart), in the
/// transfer proxy's storage (GnoTransferStorage, and OpenZeppelin's AccessManaged, Initializable and reentrancy
/// state) and under its AccessManager: every governance function is `restricted`, which the deployment leaves at
/// ADMIN_ROLE (IBCAdmin). Guardian flags are their keys' own calls.
contract GnoICS20Controls is IGnoICS20Controls, ReentrancyGuardTransient, AccessManagedUpgradeable {
    /// @notice Most queued refunds one `claim` pays.
    uint256 private constant MAX_CLAIMS = 20;
    /// @notice Longest quarantine a route takes.
    uint64 private constant MAX_QUARANTINE = 365 days;

    /// @notice eureka ICS20Transfer's storage namespace, whose first field is `_escrows`.
    uint256 private constant ICS20_ESCROWS_SLOT = 0x823f7a8ea9ae6df0eb03ec5e1682d7a2839417ad8a91774118e6acf2e8d2f800;

    address private immutable _self;

    error NotDelegated();

    constructor() {
        _self = address(this);
    }

    /// @notice Only through a delegatecall: at its own address this contract has no state and no authority.
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

    // ----------------------------------------------------------------------------------------------- refunds --

    /// @inheritdoc IGnoICS20Controls
    function claim(
        string calldata clientId,
        address token,
        uint256 maxCount
    )
        external
        delegated
        nonReentrant
        returns (uint256 paid)
    {
        GnoTransferStorage.Layout storage g = _g();
        bytes32 route = _openRoute(clientId);
        GnoTransferStorage.TokenControls storage t = g.tokens[route][token];
        if (maxCount > MAX_CLAIMS) maxCount = MAX_CLAIMS;
        uint64 now_ = uint64(block.timestamp);
        while (paid < maxCount && t.head != t.tail) {
            GnoTransferStorage.QueuedRefund storage q = t.queue[t.head];
            SendRecord storage rec = g.records[keccak256(bytes(q.clientId))][q.sequence];
            if (rec.payment == Payment.Queued) {
                uint256 remaining = GnoTransferStorage.refundable(rec);
                uint256 got = LeakyBucket.available(t.refunded, t.limits.refundCap, now_);
                if (got > remaining) got = remaining;
                if (got == 0 && remaining != 0) break;
                if (got != 0 && GnoTransferStorage.tryPayRefund(rec, got)) {
                    LeakyBucket.charge(t.refunded, t.limits.refundCap, got, now_);
                    emit GnoRefundPaid(q.clientId, q.sequence, token, rec.sender, got);
                    if (got != remaining) break; // an installment: the meter is empty
                    rec.payment = Payment.Claimed;
                    GnoTransferStorage.releaseNotice(rec, q.clientId, q.sequence);
                } else if (got != 0) {
                    // a refund the token refuses waits apart, so the refunds behind it are paid
                    rec.payment = Payment.Parked;
                    emit GnoRefundParked(q.clientId, q.sequence, token, remaining);
                }
                emit GnoOutcomeRecorded(q.clientId, q.sequence, rec.outcome, rec.payment);
            }
            // an entry kind 12 settled (rejected, paid or parked) leaves the queue without a payment
            delete t.queue[t.head++];
            ++paid;
        }
    }

    /// @inheritdoc IGnoICS20Controls
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
            emit GnoOutcomeRecorded(clientId, sequence, rec.outcome, Payment.Claimed);
            GnoTransferStorage.releaseNotice(rec, clientId, sequence);
        }
    }

    /// @notice A route whose refunds may be paid: not closed (its refunds wait for kind 12's reconciliation) and
    /// not under a refunds hold.
    function _openRoute(string calldata clientId) private view returns (bytes32 route) {
        route = GnoTransferStorage.routeHash(clientId);
        require(!_g().routes[route].closed, GnoRouteClosed(clientId));
        require(!GnoTransferStorage.refundsHeld(route), GnoRefundsHeld(clientId));
    }

    // -------------------------------------------------------------------------------------- reconciliation --

    /// @inheritdoc IGnoICS20Controls
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
            if (action == 1) {
                uint256 left = rec.amount - rec.refunded;
                require(it.amount != 0 && it.amount <= left, GnoBadSettlement(i));
                rec.settlement = 1;
                rec.entitlement = rec.refunded + it.amount;
                if (GnoTransferStorage.tryPayRefund(rec, it.amount)) {
                    rec.payment = Payment.Claimed;
                    emit GnoRefundPaid(clientId, it.sequence, rec.token, rec.sender, it.amount);
                    GnoTransferStorage.releaseNotice(rec, clientId, it.sequence);
                } else {
                    rec.payment = Payment.Parked;
                    emit GnoRefundParked(clientId, it.sequence, rec.token, it.amount);
                }
            } else if (action == 2 || action == 3) {
                require(action == 3 || owed, GnoBadSettlement(i));
                rec.settlement = action;
                if (owed) {
                    rec.payment = Payment.Rejected;
                    emit GnoRefundRejected(clientId, it.sequence);
                }
            } else if (action == 4) {
                require(it.amount != 0, GnoBadSettlement(i));
                rec.settlement = 4;
                g.losses[route][rec.token] += it.amount;
                emit GnoLossRecorded(GnoTransferStorage.routeKey(clientId), rec.token, it.sequence, it.amount);
            } else {
                revert GnoBadSettlement(i);
            }
            emit GnoSettled(clientId, it.sequence, action, it.amount);
        }
    }

    /// @inheritdoc IGnoICS20Controls
    function reopenRoute(string calldata clientId) external delegated restricted {
        GnoTransferStorage.Route storage r = _route(clientId);
        require(r.closed, GnoNotClosed(clientId));
        r.closed = false;
        emit GnoRouteReopened(GnoTransferStorage.routeKey(clientId));
    }

    /// @inheritdoc IGnoICS20Controls
    function backfill(IICS26RouterMsgs.Packet calldata packet) external delegated nonReentrant {
        require(
            packet.payloads.length == 1
                && keccak256(bytes(packet.payloads[0].sourcePort)) == ICS20Lib.KECCAK256_DEFAULT_PORT_ID,
            GnoBadBackfill()
        );
        bytes32 commitment = ICS24Host.packetCommitmentBytes32(packet);
        address router = _router();
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
        address token = _registered(string(GnoTransferStorage.toRouteDenom(bytes(data.denom))));
        if (token == address(0)) {
            require(!burned, GnoBadBackfill());
            token = ICS20Lib.mustHexStringToAddress(data.denom);
        }
        rec.commitment = commitment;
        rec.sender = ICS20Lib.mustHexStringToAddress(data.sender);
        rec.token = token;
        rec.escrow = _escrowOf(GnoTransferStorage.routeKey(packet.sourceClient));
        rec.timeoutTimestamp = packet.timeoutTimestamp;
        rec.sendBlock = uint64(block.number);
        rec.burned = burned;
        rec.amount = data.amount;
        rec.legacy = true;
        emit GnoBackfilled(packet.sourceClient, packet.sequence, commitment);
    }

    // --------------------------------------------------------------------------------------------- guardians --

    function _flag(string calldata clientId, bool refunds, bool set) private {
        GnoTransferStorage.Layout storage g = _g();
        GnoTransferStorage.Route storage r = _route(clientId);
        Guardians.Flags storage f = refunds ? r.refundFlags : r.flags;
        uint64 grace = GnoTransferStorage.GRACE;
        uint256 i = set
            ? Guardians.setFlag(g.keys, f, _msgSender(), uint64(block.number), uint64(block.timestamp), grace)
            : Guardians.clearFlag(g.keys, f, _msgSender(), uint64(block.number), uint64(block.timestamp), grace);
        string memory key = GnoTransferStorage.routeKey(clientId);
        // forge-lint: disable-next-line(unsafe-typecast)
        if (set) emit GnoRouteFlagSet(key, _msgSender(), uint8(i), refunds);
        // forge-lint: disable-next-line(unsafe-typecast)
        else emit GnoRouteFlagCleared(key, _msgSender(), uint8(i), refunds);
    }

    /// @inheritdoc IGnoICS20Controls
    function setRouteFlag(string calldata clientId) external delegated {
        _flag(clientId, false, true);
    }

    /// @inheritdoc IGnoICS20Controls
    function clearRouteFlag(string calldata clientId) external delegated {
        _flag(clientId, false, false);
    }

    /// @inheritdoc IGnoICS20Controls
    function setRefundsFlag(string calldata clientId) external delegated {
        _flag(clientId, true, true);
    }

    /// @inheritdoc IGnoICS20Controls
    function clearRefundsFlag(string calldata clientId) external delegated {
        _flag(clientId, true, false);
    }

    // -------------------------------------------------------------------------------------------- governance --

    /// @inheritdoc IGnoICS20Controls
    function initializeGno(address[6] calldata keys) external delegated restricted reinitializer(3) {
        _setKeys(keys);
    }

    /// @inheritdoc IGnoICS20Controls
    function setGuardianKeys(address[6] calldata keys) external delegated restricted {
        _setKeys(keys);
    }

    function _setKeys(address[6] calldata keys) private {
        Guardians.setKeys(_g().keys, keys, uint64(block.number));
        emit GnoGuardianKeysSet(keys);
    }

    /// @inheritdoc IGnoICS20Controls
    function setLimits(string calldata clientId, address token, Limits calldata l) external delegated restricted {
        require(
            token != address(0) && l.dayCap <= LeakyBucket.MAX_CAP && l.refundCap <= LeakyBucket.MAX_CAP
                && (l.sendMax == 0 || l.sendMin <= l.sendMax),
            GnoBadLimits()
        );
        GnoTransferStorage.TokenControls storage t = _g().tokens[GnoTransferStorage.routeHash(clientId)][token];
        // the buckets drain at the old caps up to now; the new caps apply from now on
        uint64 now_ = uint64(block.timestamp);
        LeakyBucket.settle(t.received, t.limits.dayCap, now_);
        LeakyBucket.settle(t.refunded, t.limits.refundCap, now_);
        t.set = true;
        t.limits = l;
        emit GnoLimitsSet(GnoTransferStorage.routeKey(clientId), token, l);
    }

    /// @inheritdoc IGnoICS20Controls
    function setQuarantine(string calldata clientId, uint64 seconds_) external delegated restricted {
        require(seconds_ <= MAX_QUARANTINE, GnoBadLimits());
        GnoTransferStorage.Route storage r = _route(clientId);
        // the transitions accepted so far keep the deadline the old duration gave them
        (address lc, uint64 last) = _lastTransition(clientId);
        uint256 until = GnoTransferStorage.quarantineUntil(r, lc, last);
        r.quarantineDeadline = until > type(uint64).max ? type(uint64).max : uint64(until);
        (r.seenClient, r.seenTransition) = (lc, last);
        r.quarantineSeconds = seconds_;
        emit GnoQuarantineSet(GnoTransferStorage.routeKey(clientId), seconds_);
    }

    /// @inheritdoc IGnoICS20Controls
    function unpauseRoute(
        string calldata clientId,
        uint64 beforeBlock
    )
        external
        delegated
        restricted
        returns (uint256 cleared)
    {
        GnoTransferStorage.Layout storage g = _g();
        GnoTransferStorage.Route storage r = _route(clientId);
        uint64 b = uint64(block.number);
        uint64 t = uint64(block.timestamp);
        uint64 grace = GnoTransferStorage.GRACE;
        // refused while either flag set holds (two guardian flags): the refunds hold follows the ordinary rules
        cleared = Guardians.unpause(g.keys, r.flags, beforeBlock, b, t, grace)
            + Guardians.unpause(g.keys, r.refundFlags, beforeBlock, b, t, grace);
        emit GnoRouteUnpaused(GnoTransferStorage.routeKey(clientId), beforeBlock, cleared);
    }

    /// @inheritdoc IGnoICS20Controls
    function setRecoveryBlock(string calldata clientId, bool blocked) external delegated restricted {
        _route(clientId).recoveryBlocked = blocked;
        emit GnoRecoveryBlockSet(GnoTransferStorage.routeKey(clientId), blocked);
    }

    /// @inheritdoc IGnoICS20Controls
    function migrateRoute(string calldata oldClientId, string calldata newClientId) external delegated restricted {
        GnoTransferStorage.Layout storage g = _g();
        // the new id must be fresh: no alias, not a route key, no escrow of its own, never retired, not the old one
        require(
            bytes(newClientId).length != 0 && keccak256(bytes(newClientId)) != keccak256(bytes(oldClientId))
                && !g.retired[oldClientId] && !g.retired[newClientId] && bytes(g.routeOf[newClientId]).length == 0
                && bytes(g.currentOf[newClientId]).length == 0 && _escrowOf(newClientId) == address(0),
            GnoBadRoute()
        );
        string memory key = GnoTransferStorage.routeKey(oldClientId);
        g.routeOf[newClientId] = key;
        g.currentOf[key] = newClientId;
        g.retired[oldClientId] = true;
        // closed until its records are reconciled (kind 12) and it is reopened (kind 13)
        g.routes[keccak256(bytes(key))].closed = true;
        emit GnoRouteMigrated(oldClientId, newClientId, key);
    }

    /// @notice eureka ICS20Transfer's `_ics26`, the router (fourth field of its namespace).
    function _router() private view returns (address router) {
        uint256 slot = ICS20_ESCROWS_SLOT + 3;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            router := sload(slot)
        }
    }

    /// @notice eureka ICS20Transfer's `_ibcERC20Contracts[denom]` (second field of its namespace).
    function _registered(string memory denom) private view returns (address token) {
        bytes32 slot = keccak256(abi.encodePacked(denom, ICS20_ESCROWS_SLOT + 1));
        // solhint-disable-next-line no-inline-assembly
        assembly {
            token := sload(slot)
        }
    }

    /// @notice The route's light client and its latest live transition (zero when the router or the client cannot
    /// tell: a client without the quarantine views has no transitions to keep).
    function _lastTransition(string calldata clientId) private view returns (address lc, uint64 last) {
        (bool ok, bytes memory ret) = _router().staticcall(abi.encodeCall(IICS02Client.getClient, (clientId)));
        if (!ok || ret.length != 32) return (address(0), 0);
        lc = abi.decode(ret, (address));
        (ok, ret) = lc.staticcall(abi.encodeCall(IGnoLightClientStatus.lastTransitionTime, ()));
        if (ok && ret.length == 32) last = abi.decode(ret, (uint64));
    }

    /// @notice eureka ICS20Transfer's `_escrows[key]`: the first field of its ERC-7201 namespace
    /// (`ibc.storage.ICS20Transfer`, slot 0x823f...f800), a mapping from string.
    function _escrowOf(string memory key) private view returns (address escrow) {
        bytes32 slot = keccak256(abi.encodePacked(key, ICS20_ESCROWS_SLOT));
        // solhint-disable-next-line no-inline-assembly
        assembly {
            escrow := sload(slot)
        }
    }

    // ------------------------------------------------------------------------------------------------- views --

    /// @inheritdoc IGnoICS20Controls
    function routeKey(string calldata clientId) external view delegated returns (string memory) {
        return GnoTransferStorage.routeKey(clientId);
    }

    /// @inheritdoc IGnoICS20Controls
    function currentClient(string calldata routeKey_) external view delegated returns (string memory) {
        string memory c = _g().currentOf[routeKey_];
        return bytes(c).length == 0 ? routeKey_ : c;
    }

    /// @inheritdoc IGnoICS20Controls
    function isRetired(string calldata clientId) external view delegated returns (bool) {
        return _g().retired[clientId];
    }

    /// @inheritdoc IGnoICS20Controls
    function guardianKeys() external view delegated returns (address[6] memory) {
        return _g().keys.keys;
    }

    /// @inheritdoc IGnoICS20Controls
    function routeFlags(string calldata clientId) external view delegated returns (IGuardians.Flag[6] memory) {
        return Guardians.flags(_g().keys, _route(clientId).flags);
    }

    /// @inheritdoc IGnoICS20Controls
    function refundsFlags(string calldata clientId) external view delegated returns (IGuardians.Flag[6] memory) {
        return Guardians.flags(_g().keys, _route(clientId).refundFlags);
    }

    /// @inheritdoc IGnoICS20Controls
    function routeHold(string calldata clientId) external view delegated returns (IGuardians.Flag memory) {
        return Guardians.holdView(_g().keys, _route(clientId).flags, uint64(block.timestamp), GnoTransferStorage.GRACE);
    }

    /// @inheritdoc IGnoICS20Controls
    function routeClosed(string calldata clientId) external view delegated returns (bool) {
        return _route(clientId).closed;
    }

    /// @inheritdoc IGnoICS20Controls
    function losses(string calldata clientId, address token) external view delegated returns (uint256) {
        return _g().losses[GnoTransferStorage.routeHash(clientId)][token];
    }

    /// @inheritdoc IGnoICS20Controls
    function refundsHold(string calldata clientId) external view delegated returns (IGuardians.Flag memory) {
        return Guardians.holdView(
            _g().keys, _route(clientId).refundFlags, uint64(block.timestamp), GnoTransferStorage.GRACE
        );
    }

    /// @inheritdoc IGnoICS20Controls
    function routePaused(string calldata clientId) external view delegated returns (bool) {
        return Guardians.anyFlag(_g().keys, _route(clientId).flags);
    }

    /// @inheritdoc IGnoICS20Controls
    function refundsHeld(string calldata clientId) external view delegated returns (bool) {
        return GnoTransferStorage.refundsHeld(GnoTransferStorage.routeHash(clientId));
    }

    /// @inheritdoc IGnoICS20Controls
    function limits(string calldata clientId, address token) external view delegated returns (LimitsView memory v) {
        GnoTransferStorage.TokenControls storage t = _g().tokens[GnoTransferStorage.routeHash(clientId)][token];
        v.set = t.set;
        v.limits = t.limits;
        v.receiveLevel = LeakyBucket.level(t.received, t.limits.dayCap, uint64(block.timestamp));
        v.refundLevel = LeakyBucket.level(t.refunded, t.limits.refundCap, uint64(block.timestamp));
    }

    /// @inheritdoc IGnoICS20Controls
    function quarantineSeconds(string calldata clientId) external view delegated returns (uint64) {
        return _route(clientId).quarantineSeconds;
    }

    /// @inheritdoc IGnoICS20Controls
    function recoveryBlocked(string calldata clientId) external view delegated returns (bool) {
        return _route(clientId).recoveryBlocked;
    }

    /// @inheritdoc IGnoICS20Controls
    function sendRecord(string calldata clientId, uint64 sequence) external view delegated returns (SendRecord memory) {
        return _g().records[keccak256(bytes(clientId))][sequence];
    }

    /// @inheritdoc IGnoICS20Controls
    function refundQueue(
        string calldata clientId,
        address token
    )
        external
        view
        delegated
        returns (uint64 head, uint64 tail)
    {
        GnoTransferStorage.TokenControls storage t = _g().tokens[GnoTransferStorage.routeHash(clientId)][token];
        return (t.head, t.tail);
    }
}
