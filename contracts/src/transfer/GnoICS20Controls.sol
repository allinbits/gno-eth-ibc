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
import { IGnoICS20ControlsTypes } from "../interfaces/IGnoICS20Controls.sol";
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
contract GnoICS20Controls is IGnoICS20ControlsTypes, ReentrancyGuardTransient, AccessManagedUpgradeable {
    /// @notice Most queued refunds one `claim` pays.
    uint256 private constant MAX_CLAIMS = 20;
    /// @notice Longest quarantine a route takes.
    uint64 private constant MAX_QUARANTINE = 365 days;

    address private immutable _self;
    /// @notice GnoICS20Reconcile: the reconciliation functions, served by this contract's fallback.
    address public immutable RECONCILE;

    error NotDelegated();

    constructor(address reconcile) {
        _self = address(this);
        RECONCILE = reconcile;
    }

    /// @notice Serves the reconciliation functions (claimParked, settleRecords, reopenRoute, backfill) from
    /// GnoICS20Reconcile, in the transfer proxy's storage (EIP-170 keeps them apart).
    // solhint-disable-next-line no-complex-fallback
    fallback() external {
        address r = RECONCILE;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), r, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch ok
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
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

    /// @notice See IGnoICS20Controls.
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

    /// @notice A route whose refunds may be paid: not closed (its refunds wait for kind 12's reconciliation) and
    /// not under a refunds hold.
    function _openRoute(string calldata clientId) private view returns (bytes32 route) {
        route = GnoTransferStorage.routeHash(clientId);
        require(!_g().routes[route].closed, GnoRouteClosed(clientId));
        require(!GnoTransferStorage.refundsHeld(route), GnoRefundsHeld(clientId));
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

    /// @notice See IGnoICS20Controls.
    function setRouteFlag(string calldata clientId) external delegated {
        _flag(clientId, false, true);
    }

    /// @notice See IGnoICS20Controls.
    function clearRouteFlag(string calldata clientId) external delegated {
        _flag(clientId, false, false);
    }

    /// @notice See IGnoICS20Controls.
    function setRefundsFlag(string calldata clientId) external delegated {
        _flag(clientId, true, true);
    }

    /// @notice See IGnoICS20Controls.
    function clearRefundsFlag(string calldata clientId) external delegated {
        _flag(clientId, true, false);
    }

    // -------------------------------------------------------------------------------------------- governance --

    /// @notice See IGnoICS20Controls.
    function initializeGno(address[6] calldata keys) external delegated restricted reinitializer(3) {
        _setKeys(keys);
    }

    /// @notice See IGnoICS20Controls.
    function setGuardianKeys(address[6] calldata keys) external delegated restricted {
        _setKeys(keys);
    }

    function _setKeys(address[6] calldata keys) private {
        Guardians.setKeys(_g().keys, keys, uint64(block.number));
        emit GnoGuardianKeysSet(keys);
    }

    /// @notice See IGnoICS20Controls.
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

    /// @notice See IGnoICS20Controls.
    function setQuarantine(string calldata clientId, uint64 seconds_) external delegated restricted {
        require(seconds_ <= MAX_QUARANTINE, GnoBadLimits());
        GnoTransferStorage.Route storage r = _route(clientId);
        // the transitions accepted so far keep the deadline the old duration gave them
        (address lc, uint64 id, uint64 time) = _lastTransition(clientId);
        uint256 until = GnoTransferStorage.quarantineUntil(r, lc, id, time);
        r.quarantineDeadline = until > type(uint64).max ? type(uint64).max : uint64(until);
        (r.seenClient, r.seenTransition) = (lc, id);
        r.quarantineSeconds = seconds_;
        emit GnoQuarantineSet(GnoTransferStorage.routeKey(clientId), seconds_);
    }

    /// @notice See IGnoICS20Controls.
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

    /// @notice See IGnoICS20Controls.
    function setRecoveryBlock(string calldata clientId, bool blocked) external delegated restricted {
        _route(clientId).recoveryBlocked = blocked;
        emit GnoRecoveryBlockSet(GnoTransferStorage.routeKey(clientId), blocked);
    }

    /// @notice See IGnoICS20Controls.
    function migrateRoute(string calldata oldClientId, string calldata newClientId) external delegated restricted {
        GnoTransferStorage.Layout storage g = _g();
        // the new id must be fresh: no alias, not a route key, no escrow of its own, never retired, not the old one
        require(
            bytes(newClientId).length != 0 && keccak256(bytes(newClientId)) != keccak256(bytes(oldClientId))
                && !g.retired[oldClientId] && !g.retired[newClientId] && bytes(g.routeOf[newClientId]).length == 0
                && bytes(g.currentOf[newClientId]).length == 0
                && GnoTransferStorage.ics20Escrow(newClientId) == address(0),
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

    /// @notice The route's current light client and its latest live transition (zero when the router or the client
    /// cannot tell: a client without the quarantine views has no transitions to keep).
    function _lastTransition(string calldata clientId) private view returns (address lc, uint64 id, uint64 time) {
        // the route's current client, whichever of its ids names it: a retired id's client is frozen
        string memory key = GnoTransferStorage.routeKey(clientId);
        string memory current = _g().currentOf[key];
        if (bytes(current).length == 0) current = key;
        (bool ok, bytes memory ret) =
            GnoTransferStorage.ics20Router().staticcall(abi.encodeCall(IICS02Client.getClient, (current)));
        if (!ok || ret.length != 32) return (address(0), 0, 0);
        lc = abi.decode(ret, (address));
        (ok, ret) = lc.staticcall(abi.encodeCall(IGnoLightClientStatus.lastTransition, ()));
        if (ok && ret.length == 64) (id, time) = abi.decode(ret, (uint64, uint64));
    }

    // ------------------------------------------------------------------------------------------------- views --

    /// @notice See IGnoICS20Controls.
    function routeKey(string calldata clientId) external view delegated returns (string memory) {
        return GnoTransferStorage.routeKey(clientId);
    }

    /// @notice See IGnoICS20Controls.
    function currentClient(string calldata routeKey_) external view delegated returns (string memory) {
        string memory c = _g().currentOf[routeKey_];
        return bytes(c).length == 0 ? routeKey_ : c;
    }

    /// @notice See IGnoICS20Controls.
    function isRetired(string calldata clientId) external view delegated returns (bool) {
        return _g().retired[clientId];
    }

    /// @notice See IGnoICS20Controls.
    function guardianKeys() external view delegated returns (address[6] memory) {
        return _g().keys.keys;
    }

    /// @notice See IGnoICS20Controls.
    function routeFlags(string calldata clientId) external view delegated returns (IGuardians.Flag[6] memory) {
        return Guardians.flags(_g().keys, _route(clientId).flags);
    }

    /// @notice See IGnoICS20Controls.
    function refundsFlags(string calldata clientId) external view delegated returns (IGuardians.Flag[6] memory) {
        return Guardians.flags(_g().keys, _route(clientId).refundFlags);
    }

    /// @notice See IGnoICS20Controls.
    function routeHold(string calldata clientId) external view delegated returns (IGuardians.Flag memory) {
        return Guardians.holdView(_g().keys, _route(clientId).flags, uint64(block.timestamp), GnoTransferStorage.GRACE);
    }

    /// @notice See IGnoICS20Controls.
    function routeClosed(string calldata clientId) external view delegated returns (bool) {
        return _route(clientId).closed;
    }

    /// @notice See IGnoICS20Controls.
    function losses(string calldata clientId, address token) external view delegated returns (uint256) {
        return _g().losses[GnoTransferStorage.routeHash(clientId)][token];
    }

    /// @notice See IGnoICS20Controls.
    function refundsHold(string calldata clientId) external view delegated returns (IGuardians.Flag memory) {
        return Guardians.holdView(
            _g().keys, _route(clientId).refundFlags, uint64(block.timestamp), GnoTransferStorage.GRACE
        );
    }

    /// @notice See IGnoICS20Controls.
    function routePaused(string calldata clientId) external view delegated returns (bool) {
        return Guardians.anyFlag(_g().keys, _route(clientId).flags);
    }

    /// @notice See IGnoICS20Controls.
    function refundsHeld(string calldata clientId) external view delegated returns (bool) {
        return GnoTransferStorage.refundsHeld(GnoTransferStorage.routeHash(clientId));
    }

    /// @notice See IGnoICS20Controls.
    function limits(string calldata clientId, address token) external view delegated returns (LimitsView memory v) {
        GnoTransferStorage.TokenControls storage t = _g().tokens[GnoTransferStorage.routeHash(clientId)][token];
        v.set = t.set;
        v.limits = t.limits;
        v.receiveLevel = LeakyBucket.level(t.received, t.limits.dayCap, uint64(block.timestamp));
        v.refundLevel = LeakyBucket.level(t.refunded, t.limits.refundCap, uint64(block.timestamp));
    }

    /// @notice See IGnoICS20Controls.
    function quarantineSeconds(string calldata clientId) external view delegated returns (uint64) {
        return _route(clientId).quarantineSeconds;
    }

    /// @notice See IGnoICS20Controls.
    function recoveryBlocked(string calldata clientId) external view delegated returns (bool) {
        return _route(clientId).recoveryBlocked;
    }

    /// @notice See IGnoICS20Controls.
    function sendRecord(string calldata clientId, uint64 sequence) external view delegated returns (SendRecord memory) {
        return _g().records[keccak256(bytes(clientId))][sequence];
    }

    /// @notice See IGnoICS20Controls.
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
