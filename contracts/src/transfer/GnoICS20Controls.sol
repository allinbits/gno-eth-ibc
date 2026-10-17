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
    /// @notice The reconciliation module's code hash when this module was built (see GnoICS20Transfer).
    bytes32 public immutable RECONCILE_HASH;

    error NotDelegated();

    constructor(address reconcile) {
        require(reconcile.code.length != 0, GnoBadModule());
        _self = address(this);
        RECONCILE = reconcile;
        RECONCILE_HASH = reconcile.codehash;
    }

    /// @notice The controls version this module implements (kind 7 checks it on the module and through the proxy).
    function gnoControlsModuleVersion() external pure returns (uint256) {
        return 1;
    }

    /// @notice The address this module recorded as its own at construction (kind 7 requires it to be the module's
    /// address: a module whose recorded address is another, such as the proxy's, would refuse every delegated call).
    function gnoSelf() external view returns (address) {
        return _self;
    }

    /// @notice Serves the reconciliation functions (claimParked, settleRecords, reopenRoute, continueReopen) from
    /// GnoICS20Reconcile, in the transfer proxy's storage (EIP-170 keeps them apart).
    // solhint-disable-next-line no-complex-fallback
    fallback() external {
        address r = RECONCILE;
        require(r.codehash == RECONCILE_HASH, GnoBadModule());
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
                uint256 reservedBefore = GnoTransferStorage.reservation(rec);
                uint256 remaining = GnoTransferStorage.refundable(rec);
                // the meter charged first (checks-effects-interactions), given back if the payment fails
                LeakyBucket.Bucket memory meter = t.refunded;
                uint256 got = LeakyBucket.chargeUpTo(t.refunded, t.limits.refundCap, remaining, now_);
                if (got == 0 && remaining != 0) break;
                if (got != 0 && GnoTransferStorage.tryPayRefund(rec, got, route, reservedBefore, 0)) {
                    emit GnoRefundPaid(q.clientId, q.sequence, token, rec.sender, got);
                    if (got != remaining) {
                        // an installment: the meter is empty
                        GnoTransferStorage.syncReserve(route, rec, reservedBefore);
                        break;
                    }
                    rec.payment = Payment.Claimed;
                    GnoTransferStorage.closeRecord(rec, keccak256(bytes(q.clientId)));
                    GnoTransferStorage.releaseNotice(q.clientId, q.sequence);
                } else if (got != 0) {
                    // a refund the token refuses waits apart, so the refunds behind it are paid
                    t.refunded = meter;
                    rec.payment = Payment.Parked;
                    emit GnoRefundParked(q.clientId, q.sequence, token, remaining);
                }
                GnoTransferStorage.syncReserve(route, rec, reservedBefore);
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

    // ------------------------------------------------------------------------------------------ the ack hook --

    error NotHook();

    /// @notice Only through GnoICS20Transfer's own call (`_ackHook`): it sets a transient flag that this consumes, so
    /// no call through the fallback, and no call nested inside the hook (a token's transfer hook), can reach it.
    modifier onlyHook() {
        uint256 f;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            f := tload(0xfe384f8ea4975d6b603976442788326f3f0c6e1e07e29205223544c80bcce885)
            tstore(0xfe384f8ea4975d6b603976442788326f3f0c6e1e07e29205223544c80bcce885, 0)
        }
        if (f != 1) revert NotHook();
        _;
    }

    /// @notice Attaches an ack's or timeout's outcome to the packet's send record (§7.13). A success notifies the
    /// sender. An error ack or timeout pays the refund at once when the refund meter has room, no refunds hold
    /// stands, the route is open and nothing is queued before it; otherwise queues it for `claim`. A token refusing
    /// the payment parks it for `claimParked`. Never reverts for the meter, the hold or a refusal: a refund is
    /// delayed, never refused. The sender is notified when the refund is paid.
    function ackHook(
        string calldata clientId,
        uint64 sequence,
        Outcome outcome,
        address token,
        address refundee,
        uint256 amount,
        bytes calldata notice
    )
        external
        delegated
        onlyHook
    {
        GnoTransferStorage.Layout storage g = _g();
        SendRecord storage rec = g.records[keccak256(bytes(clientId))][sequence];
        // every packet the transfer app sent has a record (the deployment is fresh)
        require(rec.commitment != bytes32(0), GnoNoSendRecord(clientId, sequence));
        // a record reconciliation settled is final: a later ack or timeout pays nothing and notifies nobody (the
        // router's commitment is consumed as usual)
        if (rec.settlement != 0) {
            emit GnoOutcomeIgnored(clientId, sequence, outcome);
            return;
        }
        // the outstanding send's reservation, which this outcome resolves
        uint256 reservedBefore = GnoTransferStorage.reservation(rec);
        rec.outcome = outcome;
        rec.processedBlock = uint64(block.number);
        bytes32 route = GnoTransferStorage.routeHash(clientId);
        GnoTransferStorage.Route storage r = g.routes[route];
        bytes32 clientHash = keccak256(bytes(clientId));
        GnoTransferStorage.ClientRecon storage c = g.clients[clientHash];
        rec.processedIndex = uint64(c.processed.length);
        c.processed.push(uint64(block.number));
        // processed on a retired client (its incident's reconciliation under way): one more suspect record; the live
        // client's never count
        if (c.incident != 0) {
            bool had = GnoTransferStorage.hasWork(c);
            ++c.suspectOpen;
            GnoTransferStorage.noteWork(c, had);
        }
        if (outcome == Outcome.Success) {
            GnoTransferStorage.closeRecord(rec, clientHash);
            GnoTransferStorage.syncReserve(route, rec, reservedBefore);
            emit GnoOutcomeRecorded(clientId, sequence, outcome, rec.payment);
            GnoTransferStorage.notify(refundee, notice, clientId, sequence);
            return;
        }
        // the record is the send's: it must name this refund
        require(
            rec.token == token && rec.sender == refundee && rec.amount == amount, GnoNoSendRecord(clientId, sequence)
        );
        GnoTransferStorage.TokenControls storage t = g.tokens[route][token];
        uint64 now_ = uint64(block.timestamp);
        bool paid;
        LeakyBucket.Bucket memory meter = t.refunded;
        // the meter charged first (checks-effects-interactions), given back if the payment fails
        if (
            t.head == t.tail && !GnoTransferStorage.refundsHeld(route) && !r.closed
                && LeakyBucket.charge(t.refunded, t.limits.refundCap, amount, now_)
        ) {
            if (GnoTransferStorage.tryPayRefund(rec, amount, route, reservedBefore, 0)) {
                rec.payment = Payment.Paid;
                GnoTransferStorage.closeRecord(rec, clientHash);
                paid = true;
                emit GnoRefundPaid(clientId, sequence, token, refundee, amount);
            } else {
                t.refunded = meter;
                rec.payment = Payment.Parked;
                emit GnoRefundParked(clientId, sequence, token, amount);
            }
        } else {
            t.queue[t.tail++] = GnoTransferStorage.QueuedRefund(clientId, sequence);
            rec.payment = Payment.Queued;
            emit GnoRefundQueued(clientId, sequence, token, amount);
        }
        GnoTransferStorage.syncReserve(route, rec, reservedBefore);
        emit GnoOutcomeRecorded(clientId, sequence, outcome, rec.payment);
        if (paid) GnoTransferStorage.notify(refundee, notice, clientId, sequence);
        else GnoTransferStorage.holdNotice(refundee, notice, clientId, sequence);
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
    function setRouteFlag(string calldata clientId) external delegated nonReentrant {
        _flag(clientId, false, true);
    }

    /// @notice See IGnoICS20Controls.
    function clearRouteFlag(string calldata clientId) external delegated nonReentrant {
        _flag(clientId, false, false);
    }

    /// @notice See IGnoICS20Controls.
    function setRefundsFlag(string calldata clientId) external delegated nonReentrant {
        _flag(clientId, true, true);
    }

    /// @notice See IGnoICS20Controls.
    function clearRefundsFlag(string calldata clientId) external delegated nonReentrant {
        _flag(clientId, true, false);
    }

    // -------------------------------------------------------------------------------------------- governance --

    /// @notice See IGnoICS20Controls.
    function initializeGno(address[6] calldata keys) external delegated restricted nonReentrant reinitializer(3) {
        _setKeys(keys);
    }

    /// @notice See IGnoICS20Controls.
    function setGuardianKeys(address[6] calldata keys) external delegated restricted nonReentrant {
        _setKeys(keys);
    }

    function _setKeys(address[6] calldata keys) private {
        Guardians.setKeys(_g().keys, keys);
        emit GnoGuardianKeysSet(keys);
    }

    /// @notice See IGnoICS20Controls.
    function setLimits(
        string calldata clientId,
        address token,
        Limits calldata l
    )
        external
        delegated
        restricted
        nonReentrant
    {
        require(
            token != address(0) && l.dayCap <= LeakyBucket.MAX_CAP && l.refundCap <= LeakyBucket.MAX_CAP
                && (l.sendMax == 0 || l.sendMin <= l.sendMax),
            GnoBadLimits()
        );
        // receive limits (which enable receives) wait for the route's quarantine
        require(_route(clientId).quarantineArmed, GnoBadLimits());
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
    function setQuarantine(string calldata clientId, uint64 seconds_) external delegated restricted nonReentrant {
        require(seconds_ <= MAX_QUARANTINE, GnoBadLimits());
        GnoTransferStorage.Route storage r = _route(clientId);
        // the transitions accepted so far keep the deadline the old duration gave them; the launch's arming has no
        // old duration: every transition since the trusted checkpoint (anyone may relay one before it) counts as
        // live with the launch duration
        if (r.quarantineArmed) _checkpoint(r, clientId);
        r.quarantineArmed = true;
        r.quarantineSeconds = seconds_;
        emit GnoQuarantineSet(GnoTransferStorage.routeKey(clientId), seconds_);
    }

    /// @notice The index of the first record processed at or after `fromBlock` (binary search; the list is in
    /// processing order).
    function _firstProcessedAt(uint64[] storage list, uint64 fromBlock) private view returns (uint256 lo) {
        uint256 hi = list.length;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (list[mid] < fromBlock) lo = mid + 1;
            else hi = mid;
        }
    }

    /// @notice See IGnoICS20Controls.
    function checkpointQuarantine(string calldata clientId) external delegated restricted nonReentrant {
        GnoTransferStorage.Route storage r = _route(clientId);
        _checkpoint(r, clientId);
        // called before every verifier swap: outcomes proven through the old verifier are void
        ++r.verifierGen;
    }

    /// @notice Stores the deadline the route's current client's transitions set so far (each with the duration in
    /// force), so neither a duration change nor a verifier swap can drop it.
    function _checkpoint(GnoTransferStorage.Route storage r, string calldata clientId) private {
        (address lc, uint64 id, uint64 time) = _lastTransition(clientId);
        uint256 until = GnoTransferStorage.quarantineUntil(r, lc, id, time);
        r.quarantineDeadline = until > type(uint64).max ? type(uint64).max : uint64(until);
        (r.seenClient, r.seenTransition) = (lc, id);
    }

    /// @notice See IGnoICS20Controls.
    function unpauseRoute(
        string calldata clientId,
        uint64 beforeBlock
    )
        external
        delegated
        restricted
        nonReentrant
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
    function setRecoveryBlock(string calldata clientId, bool blocked) external delegated restricted nonReentrant {
        _route(clientId).recoveryBlocked = blocked;
        emit GnoRecoveryBlockSet(GnoTransferStorage.routeKey(clientId), blocked);
    }

    /// @notice See IGnoICS20Controls.
    function migrateRoute(
        string calldata oldClientId,
        string calldata newClientId,
        uint64 suspectFrom
    )
        external
        delegated
        restricted
        nonReentrant
    {
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
        GnoTransferStorage.Route storage r = g.routes[keccak256(bytes(key))];
        // only the route's current client is replaced; also while the route is closed (an earlier incident's
        // reconciliation unfinished: it carries over untouched), and a reopening under way is aborted
        string memory current = bytes(g.currentOf[key]).length == 0 ? key : g.currentOf[key];
        require(keccak256(bytes(current)) == keccak256(bytes(oldClientId)), GnoBadRoute());
        GnoTransferStorage.abortReopening(r, key);
        g.routeOf[newClientId] = key;
        g.currentOf[key] = newClientId;
        g.retired[oldClientId] = true;
        // closed until every incident is reconciled (kind 12) and the route reopened (kind 13)
        r.closed = true;
        ++r.verifierGen;
        // the new incident covers the retired client: its acks and timeouts processed from `suspectFrom` on must be
        // settled by kind 12 before kind 13 (ADR §7.12); the client's own list holds only its records
        bytes32 oldHash = keccak256(bytes(oldClientId));
        r.incidents.push(Incident(GnoTransferStorage.REPLACEMENT, GnoTransferStorage.OPEN, oldHash, suspectFrom));
        GnoTransferStorage.ClientRecon storage c = g.clients[oldHash];
        uint256 start = _firstProcessedAt(c.processed, suspectFrom);
        c.incident = uint32(r.incidents.length);
        c.route = keccak256(bytes(key));
        c.suspectStart = uint64(start);
        c.suspectOpen = uint64(c.processed.length - start);
        if (GnoTransferStorage.hasWork(c)) ++r.pendingIncidents;
        emit GnoRouteMigrated(oldClientId, newClientId, key);
    }

    /// @notice The route's current light client and its latest live transition. Fail closed: a client whose
    /// `lastTransition()` is missing, reverts or answers anything but two uint64 words refuses (GnoQuarantineUnknown),
    /// so no quarantine is ever lost to a silent client.
    function _lastTransition(string calldata clientId) private view returns (address lc, uint64 id, uint64 time) {
        // the route's current client, whichever of its ids names it: a retired id's client is frozen
        string memory key = GnoTransferStorage.routeKey(clientId);
        string memory current = _g().currentOf[key];
        if (bytes(current).length == 0) current = key;
        (bool ok, bytes memory ret) =
            GnoTransferStorage.ics20Router().staticcall(abi.encodeCall(IICS02Client.getClient, (current)));
        require(ok && ret.length == 32, GnoQuarantineUnknown(clientId));
        lc = abi.decode(ret, (address));
        (ok, ret) = lc.staticcall(abi.encodeCall(IGnoLightClientStatus.lastTransition, ()));
        require(ok && ret.length == 64, GnoQuarantineUnknown(clientId));
        (uint256 a, uint256 b) = abi.decode(ret, (uint256, uint256));
        require(a <= type(uint64).max && b <= type(uint64).max, GnoQuarantineUnknown(clientId));
        (id, time) = (uint64(a), uint64(b));
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
    function suspectRecords(string calldata clientId) external view delegated returns (uint64 from, uint64 open) {
        GnoTransferStorage.ClientRecon storage c = _g().clients[keccak256(bytes(clientId))];
        if (c.incident != 0) from = _route(clientId).incidents[c.incident - 1].suspectFrom;
        return (from, c.suspectOpen);
    }

    /// @notice See IGnoICS20Controls.
    function routeReopening(string calldata clientId) external view delegated returns (bool) {
        return _route(clientId).reopening;
    }

    /// @notice See IGnoICS20Controls.
    function openRecords(string calldata clientId) external view delegated returns (uint64) {
        return _g().clients[keccak256(bytes(clientId))].open;
    }

    /// @notice See IGnoICS20Controls.
    function reserved(string calldata clientId, address token) external view delegated returns (uint256) {
        return _g().tokens[GnoTransferStorage.routeHash(clientId)][token].reserved;
    }

    /// @notice See IGnoICS20Controls.
    function acceptedDeficit(string calldata clientId, address token) external view delegated returns (uint256) {
        return _g().acceptedDeficit[GnoTransferStorage.routeHash(clientId)][token];
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
