// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ReentrancyGuardTransient } from "@openzeppelin-contracts/utils/ReentrancyGuardTransient.sol";
import { AccessManagedUpgradeable } from "@openzeppelin-upgradeable/access/manager/AccessManagedUpgradeable.sol";

import { IGnoICS20Controls } from "../interfaces/IGnoICS20Controls.sol";
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
        bytes32 route = GnoTransferStorage.routeHash(clientId);
        require(!GnoTransferStorage.refundsHeld(route), GnoRefundsHeld(clientId));
        GnoTransferStorage.TokenControls storage t = g.tokens[route][token];
        if (maxCount > MAX_CLAIMS) maxCount = MAX_CLAIMS;
        while (paid < maxCount && t.head != t.tail) {
            GnoTransferStorage.QueuedRefund storage q = t.queue[t.head];
            SendRecord storage rec = g.records[keccak256(bytes(q.clientId))][q.sequence];
            uint256 got = LeakyBucket.chargeUpTo(
                t.refunded, t.limits.refundCap, rec.amount - rec.refunded, uint64(block.timestamp)
            );
            if (got == 0) break;
            GnoTransferStorage.payRefund(rec, got);
            emit GnoRefundPaid(q.clientId, q.sequence, token, rec.sender, got);
            if (rec.refunded != rec.amount) break; // an installment: the meter is empty
            rec.payment = Payment.Claimed;
            emit GnoOutcomeRecorded(q.clientId, q.sequence, rec.outcome, Payment.Claimed);
            delete t.queue[t.head++];
            ++paid;
        }
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
        Guardians.checkKeys(keys);
        _g().keys = keys;
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
        t.set = true;
        t.limits = l; // the buckets' levels stand
        emit GnoLimitsSet(GnoTransferStorage.routeKey(clientId), token, l);
    }

    /// @inheritdoc IGnoICS20Controls
    function setQuarantine(string calldata clientId, uint64 seconds_) external delegated restricted {
        require(seconds_ <= MAX_QUARANTINE, GnoBadLimits());
        _route(clientId).quarantineSeconds = seconds_;
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
        // refused under a hold of the route's flags; the refunds flags (any one holds refunds) are cleared alike
        cleared = Guardians.unpause(g.keys, r.flags, beforeBlock, b, t, grace)
            + Guardians.clearBefore(g.keys, r.refundFlags, beforeBlock, b, t, grace);
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
        emit GnoRouteMigrated(oldClientId, newClientId, key);
    }

    /// @notice eureka ICS20Transfer's `_escrows[key]`: the first field of its ERC-7201 namespace
    /// (`ibc.storage.ICS20Transfer`, slot 0x823f...f800), a mapping from string.
    function _escrowOf(string calldata key) private view returns (address escrow) {
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
        return _g().keys;
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
