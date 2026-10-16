// SPDX-License-Identifier: LicenseRef-GNO-Network-GPL
pragma solidity ^0.8.28;

// Ported in part from gnolang/bridges (branch ethereum-draft), ethereum/bridge/contracts/src/HlAdmin.sol: the
// decision ledger, delays deferred by flags and holds, the guardian replacement's day-21 floor, the hold history and
// the code-hash-pinned executor. Hyperlane's `handle`/ISM plumbing is replaced by IBC v2 callbacks and the delivery
// protocol of ADR pr6375 §5.4. Copyright (C) 2026 NewTendermint, LLC. GNO Network General Public License: see
// contracts/licenses/.

import { IIBCApp } from "@eureka/interfaces/IIBCApp.sol";
import { IIBCAppCallbacks } from "@eureka/msgs/IIBCAppCallbacks.sol";
import { IICS26RouterMsgs } from "@eureka/msgs/IICS26RouterMsgs.sol";

import { IIBCAdmin } from "../interfaces/IIBCAdmin.sol";
import { IGuardians } from "../interfaces/IGuardians.sol";
import { Guardians } from "../lib/Guardians.sol";
import { IBCAdminStorage as S } from "./IBCAdminStorage.sol";
import { IBCAdminExec } from "./IBCAdminExec.sol";

/// @title IBCAdmin: the permanent governance app on port `ibcgov` (gno.land's `gov`)
/// @notice Plain code, never behind a proxy, so immutable from its deployment; router ports can never be registered
/// again, so this is the stable endpoint. After the setup it holds every authority of the deployment (the
/// AccessManager's ADMIN_ROLE, hence every proxy's upgrade, `migrateClient`, the custom-ERC20 registration, the
/// transfer controls) and acts only on decisions `ibcgov` sends from gno.land over the paired client, proven by the
/// GnoLightClient, on its own timers, on the guardians' flags, and on the optional emergency recovery (§7.12).
///
/// Delivery (§5.4): a packet carries the envelope `version u8 = 1 | epoch u32 | seq u64 | kind u8 | params`
/// (big-endian, params the ABI encoding of the kind's tuple, at most MAX_ENVELOPE = 1024 bytes in all). The app
/// acknowledgement is `epoch u32 | seq u64 | status u8 | redispatch u8`. IBCAdmin orders recording, not delivery:
///  - `seq == last + 1` is recorded, then buffered `last + 2...` in order, at most DRAIN per call (every delivery
///    drains, and so does the permissionless `drain()`);
///  - `last + 1 < seq <= last + WINDOW` is buffered with its hash;
///  - `seq <= last`, or a buffered seq, compares hashes: the same is a duplicate (no-op), another is a conflict that
///    flags IBCAdmin and is never applied;
///  - `seq > last + WINDOW` is refused (an error ack: `ibcgov` re-sends the same bytes later), except a cancel, whose
///    tombstones apply on arrival whatever its seq and which is acknowledged with `redispatch = 1`;
///  - another epoch, another client, port, version or encoding, or an envelope with no readable seq is refused;
///  - a decodable decision of an unknown kind or with bad parameters is recorded and spent.
/// Every refusal reverts with a non-empty custom error, which the router turns into an error acknowledgement.
///
/// Execution: anyone executes a recorded decision once its delay (§5.4 kind table) has passed. Every 7-day kind is
/// deferred while a flag, a hold or a conflict stands on IBCAdmin, except the guardian replacement (kind 3), which
/// lands through flags and lands through a hold no sooner than day 21 of it; an unpause (kind 2) waits 24 hours and is
/// spent under a hold of its object. The kinds' logic runs in IBCAdminExec, delegatecalled at a pinned code hash and
/// replaced only by kind 9.
contract IBCAdmin is IIBCApp, IIBCAdmin {
    /// @notice This app's port on the Ethereum router. ADR §5.4 names it `gov`, but eureka v3.0.2's router refuses a
    /// custom port id shorter than 4 characters (IBCIdentifiers.validateCustomIBCIdentifier), so it is `ibcgov`; the
    /// packets' source port is `ibcgov`'s on gno.land, `gov`.
    string public constant PORT = "ibcgov";
    /// @notice The port of `ibcgov` on gno.land: the packets' source port.
    string public constant COUNTERPARTY_PORT = "gov";
    string public constant VERSION = "ibcgov-1";
    string public constant ENCODING = "application/x-ibcgov";
    bytes32 private constant PORT_HASH = keccak256(bytes(PORT));
    bytes32 private constant COUNTERPARTY_PORT_HASH = keccak256(bytes(COUNTERPARTY_PORT));
    bytes32 private constant VERSION_HASH = keccak256(bytes(VERSION));
    bytes32 private constant ENCODING_HASH = keccak256(bytes(ENCODING));

    /// @notice The deployment's settings (§5.4, §7.12).
    struct Config {
        address router;
        address accessManager;
        address ics20;
        address exec;
        string govClientId;
        address[4] seats;
        address[2] watch;
        RecoveryConfig recovery;
    }

    address public immutable router;
    address public immutable accessManager;
    address public immutable ics20;
    /// @notice The account that deployed this contract: `finishSetup` checks it holds no role any more.
    address public immutable deployer;

    uint64 internal immutable _recoveryDelay;
    uint8 internal immutable _recoveryThreshold;
    uint8 internal immutable _recoveryCancelThreshold;
    uint64 internal immutable _recoverySilence;
    uint64 internal immutable _recoveryHoldPeriod;

    constructor(Config memory c) {
        if (c.router == address(0) || c.accessManager == address(0) || c.ics20 == address(0) || c.exec == address(0)) {
            revert ZeroAddress();
        }
        if (c.exec.code.length == 0) revert NoCodeYet(c.exec);
        (address r, address am, address t) = IBCAdminExec(c.exec).bindings();
        if (r != c.router || am != c.accessManager || t != c.ics20) revert ForeignExec();
        RecoveryConfig memory rc = c.recovery;
        if (
            rc.delay != 0
                && (rc.threshold == 0 || rc.threshold > 4 || rc.cancelThreshold == 0 || rc.cancelThreshold > 4)
        ) {
            revert RecoveryState();
        }
        router = c.router;
        accessManager = c.accessManager;
        ics20 = c.ics20;
        deployer = msg.sender;
        (_recoveryDelay, _recoveryThreshold, _recoveryCancelThreshold, _recoverySilence, _recoveryHoldPeriod) =
        (rc.delay, rc.threshold, rc.cancelThreshold, rc.silence, rc.holdPeriod);

        S.Layout storage l = S.layout();
        if (bytes(c.govClientId).length == 0) revert WrongClient(c.govClientId);
        Guardians.init(l.g, [c.seats[0], c.seats[1], c.seats[2], c.seats[3], c.watch[0], c.watch[1]]);
        l.epoch = 1;
        l.govClient = c.govClientId;
        l.lastRecordTime = uint64(block.timestamp);
        l.exec = c.exec;
        l.execHash = c.exec.codehash;
        emit EpochOpened(1, c.govClientId);
    }

    // ============================================================================================== delivery ==

    /// @inheritdoc IIBCApp
    function onRecvPacket(IIBCAppCallbacks.OnRecvPacketCallback calldata m) external returns (bytes memory) {
        if (msg.sender != router) revert NotRouter(msg.sender);
        IICS26RouterMsgs.Payload calldata p = m.payload;
        if (
            keccak256(bytes(p.sourcePort)) != COUNTERPARTY_PORT_HASH || keccak256(bytes(p.destPort)) != PORT_HASH
                || keccak256(bytes(p.version)) != VERSION_HASH || keccak256(bytes(p.encoding)) != ENCODING_HASH
        ) revert BadPayload();
        S.Layout storage l = S.layout();
        if (keccak256(bytes(m.destinationClient)) != keccak256(bytes(l.govClient))) {
            revert WrongClient(m.destinationClient);
        }
        bytes calldata e = p.value;
        if (e.length < S.HEADER || uint8(e[0]) != S.ENVELOPE_VERSION) revert Undecodable();
        uint32 ep = uint32(bytes4(e[1:5]));
        uint64 seq = uint64(bytes8(e[5:13]));
        uint8 kind = uint8(e[13]);
        if (ep != l.epoch) revert StaleEpoch(ep, l.epoch);
        if (seq == 0) revert Undecodable();
        bytes32 hash = keccak256(e);
        (uint8 status, bool redispatch) = _deliver(l, ep, seq, kind, hash, e);
        // every delivery also records what is buffered next (at most DRAIN), so a run stopped by the bound moves
        // on with the next packet as well as by `drain()`
        _drain(l, ep);
        emit DecisionReceived(ep, seq, kind, hash, status, redispatch);
        return abi.encodePacked(ep, seq, status, redispatch ? uint8(1) : uint8(0));
    }

    /// @notice IBCAdmin sends no packets.
    function onAcknowledgementPacket(IIBCAppCallbacks.OnAcknowledgementPacketCallback calldata) external pure {
        revert NotSupported();
    }

    /// @notice IBCAdmin sends no packets.
    function onTimeoutPacket(IIBCAppCallbacks.OnTimeoutPacketCallback calldata) external pure {
        revert NotSupported();
    }

    function _deliver(
        S.Layout storage l,
        uint32 ep,
        uint64 seq,
        uint8 kind,
        bytes32 hash,
        bytes calldata e
    )
        private
        returns (uint8 status, bool redispatch)
    {
        uint64 last = l.lastSeq;
        Decision storage d = l.decisions[ep][seq];
        if (seq <= last || d.state == S.BUFFERED) {
            if (d.hash == hash) return (S.STATUS_DUPLICATE, false);
            // the first bytes stand and these are never applied; the flag defers every 7-day decision
            if (l.conflictBlock == 0) l.conflictBlock = uint64(block.number);
            emit Conflict(ep, seq, d.hash, hash);
            return (S.STATUS_CONFLICT, false);
        }
        bool bad = e.length > S.MAX_ENVELOPE;
        bool cancel;
        uint64[2][] memory ranges;
        if (kind == S.KIND_CANCEL && !bad) (cancel, ranges) = _parseCancel(e[S.HEADER:]);
        if (uint256(seq) > uint256(last) + S.WINDOW) {
            if (!cancel) revert BeyondWindow(seq, last);
            _tombstone(l, ep, seq, ranges);
            return (S.STATUS_BUFFERED, true);
        }
        if (cancel) _tombstone(l, ep, seq, ranges);
        d.hash = hash;
        d.kind = kind;
        // an oversize envelope, or a cancel whose ranges do not parse, is spent when recorded
        d.bad = bad || (kind == S.KIND_CANCEL && !cancel);
        if (!d.bad && kind != S.KIND_CANCEL) d.params = e[S.HEADER:];
        if (seq == last + 1) return (_record(l, ep, seq), false);
        d.state = S.BUFFERED;
        return (S.STATUS_BUFFERED, false);
    }

    /// @notice A cancel's params: the ABI encoding of `(uint64 from, uint64 to)[]`, canonical (offset 32, 1 to
    /// MAX_CANCEL_RANGES ranges, each word a uint64, from <= to, nothing after). Parsed by hand so that malformed
    /// bytes are a "no" rather than a revert.
    function _parseCancel(bytes calldata p) private pure returns (bool, uint64[2][] memory ranges) {
        if (p.length < 64 || uint256(bytes32(p[0:32])) != 32) return (false, ranges);
        uint256 n = uint256(bytes32(p[32:64]));
        if (n == 0 || n > S.MAX_CANCEL_RANGES || p.length != 64 + 64 * n) return (false, ranges);
        ranges = new uint64[2][](n);
        for (uint256 i = 0; i < n; i++) {
            uint256 at = 64 + 64 * i;
            uint256 from = uint256(bytes32(p[at:at + 32]));
            uint256 to = uint256(bytes32(p[at + 32:at + 64]));
            if (from > type(uint64).max || to > type(uint64).max || from > to) return (false, ranges);
            ranges[i] = [uint64(from), uint64(to)];
        }
        return (true, ranges);
    }

    /// @notice Tombstones a cancel's targets, each clamped below the cancel's own number: a cancel withdraws only
    /// decisions numbered before it.
    function _tombstone(S.Layout storage l, uint32 ep, uint64 seq, uint64[2][] memory ranges) private {
        for (uint256 i = 0; i < ranges.length; i++) {
            uint64 from = ranges[i][0];
            uint64 to = ranges[i][1] < seq ? ranges[i][1] : seq - 1;
            if (from == 0) from = 1;
            if (from <= to) S.addTombstone(l, ep, from, to);
        }
    }

    /// @notice Records the decision at `last + 1`: an unknown kind or bad parameters spent, a cancel done (its
    /// tombstones applied on arrival), a tombstoned decision cancelled, an immediate one (kind 4 tightening, kind 8
    /// revoke, kind 11 lengthening) executed; the rest wait for their delay.
    function _record(S.Layout storage l, uint32 ep, uint64 seq) private returns (uint8) {
        Decision storage d = l.decisions[ep][seq];
        uint64 now_ = uint64(block.timestamp);
        l.lastSeq = seq;
        l.lastRecordTime = now_;
        d.recordedTime = now_;
        d.recordedBlock = uint64(block.number);
        uint8 kind = d.kind;
        if (d.bad || !S.knownKind(kind)) return _close(ep, seq, d, S.SPENT, d.bad ? "params" : "unknown kind");
        if (kind == S.KIND_CANCEL) return _close(ep, seq, d, S.EXECUTED, "");
        if (S.isTombstoned(l, ep, seq)) return _close(ep, seq, d, S.CANCELLED, "");
        (uint8 action, string memory reason) = _atRecording(l, kind, seq, d.params);
        if (action == S.DONE_NOW) return _close(ep, seq, d, S.EXECUTED, "");
        if (action == S.SPEND) return _close(ep, seq, d, S.SPENT, reason);
        d.state = S.PENDING;
        emit DecisionRecorded(ep, seq, kind, now_ + _delay(kind));
        return S.STATUS_RECORDED;
    }

    function _close(
        uint32 ep,
        uint64 seq,
        Decision storage d,
        uint8 state,
        string memory reason
    )
        private
        returns (uint8)
    {
        d.state = state;
        delete d.params;
        emit DecisionRecorded(ep, seq, d.kind, d.recordedTime);
        if (state == S.SPENT) {
            emit DecisionSpent(ep, seq, d.kind, reason);
            return S.STATUS_SPENT;
        }
        if (state == S.CANCELLED) emit DecisionCancelled(ep, seq);
        else emit DecisionExecuted(ep, seq, d.kind);
        return S.STATUS_RECORDED;
    }

    /// @notice The executor's verdict at recording, run with a fixed gas budget: a failure (bad parameters) spends
    /// the decision, and with less gas left than the budget needs the delivery reverts `ExecutionStarved` (an error
    /// ack: `ibcgov` re-sends), so no relayer can spend a decision by starving it. (A remaining-gas test after the
    /// call cannot tell: the proxies on the way each keep a 64th and hand it back.)
    function _atRecording(
        S.Layout storage l,
        uint8 kind,
        uint64 seq,
        bytes memory params
    )
        private
        returns (uint8, string memory)
    {
        address x = _exec(l);
        if (gasleft() < S.RECORD_FLOOR) revert ExecutionStarved();
        (bool ok, bytes memory ret) =
            x.delegatecall{ gas: S.RECORD_GAS }(abi.encodeCall(IBCAdminExec.atRecording, (kind, seq, params)));
        if (!ok) return (S.SPEND, "params");
        return abi.decode(ret, (uint8, string));
    }

    function _drain(S.Layout storage l, uint32 ep) private returns (uint256 n) {
        while (n < S.DRAIN) {
            uint64 next = l.lastSeq + 1;
            if (l.decisions[ep][next].state != S.BUFFERED) break;
            _record(l, ep, next);
            n++;
        }
    }

    /// @notice Records buffered decisions that follow the last recorded one, at most DRAIN. Permissionless.
    function drain() external returns (uint256) {
        S.Layout storage l = S.layout();
        return _drain(l, l.epoch);
    }

    // ============================================================================================= execution ==

    /// @notice Executes a recorded decision of the current epoch whose delay has passed. Permissionless. A decision
    /// whose parameters fail their checks now is spent; a call that reverts (code not deployed yet, too little gas)
    /// reverts this, and the decision stays pending.
    function execute(uint64 seq) external {
        S.Layout storage l = S.layout();
        uint32 ep = l.epoch;
        Decision storage d = l.decisions[ep][seq];
        if (d.state != S.PENDING) revert NotPending(seq);
        if (S.isTombstoned(l, ep, seq)) {
            d.state = S.CANCELLED;
            delete d.params;
            emit DecisionCancelled(ep, seq);
            return;
        }
        uint8 kind = d.kind;
        if (l.recovery.openedAt != 0 && S.suspendedByRecovery(kind)) revert Suspended();
        (bool holdStands,, uint64 holdStart) = S.hold(l);
        uint64 matureAt = d.recordedTime + _delay(kind);
        if (kind == S.KIND_SEATS) {
            if (holdStands) {
                uint64 floor = _replacementFloor(l, d.recordedTime, holdStart);
                if (floor > matureAt) matureAt = floor;
            }
        } else if (kind != S.KIND_UNPAUSE && (holdStands || S.flagged(l))) {
            revert Deferred();
        }
        if (block.timestamp < matureAt) revert NotMature(matureAt);
        // effects first: a call below that reverts reverts this, and the decision stays pending for a retry
        d.state = S.EXECUTED;
        bytes memory params = d.params;
        delete d.params;
        string memory spent =
            abi.decode(_delegate(l, abi.encodeCall(IBCAdminExec.run, (kind, seq, params, d.recordedBlock))), (string));
        if (bytes(spent).length != 0) {
            d.state = S.SPENT;
            emit DecisionSpent(ep, seq, kind, spent);
        } else {
            emit DecisionExecuted(ep, seq, kind);
        }
    }

    /// @notice An unpause waits 24 hours, every other waiting kind 7 days.
    function _delay(uint8 kind) private pure returns (uint64) {
        return kind == S.KIND_UNPAUSE ? S.DAY : S.WEEK;
    }

    /// @notice A guardian replacement's floor while a hold stands: the earliest hold overlapping [its recording,
    /// now] (the standing one, or an ended one whose end is at or after the recording) plus 21 days.
    function _replacementFloor(S.Layout storage l, uint64 recordedTime, uint64 standing) private view returns (uint64) {
        uint64 floor = standing;
        for (uint256 i = 0; i < l.holds.length; i++) {
            IGuardians.Hold memory h = l.holds[i];
            if (h.end >= recordedTime && h.start < floor) floor = h.start;
        }
        return floor + S.HOLD_REPLACEMENT;
    }

    // ================================================================================================ flags ==

    /// @notice A guardian's or watch key's own flag on IBCAdmin: defers every 7-day decision.
    function setFlag() external {
        S.Layout storage l = S.layout();
        (uint64 hb, uint64 ht, uint64 db, uint64 dt) = S.moments(l);
        uint256 i = Guardians.setFlag(l.g.keys, l.g.f, msg.sender, uint64(block.number), uint64(block.timestamp), S.DAY);
        S.noteHoldEnd(l, hb, ht, db, dt);
        // forge-lint: disable-next-line(unsafe-typecast)
        emit FlagSet(msg.sender, uint8(i));
    }

    function clearFlag() external {
        S.Layout storage l = S.layout();
        (uint64 hb, uint64 ht, uint64 db, uint64 dt) = S.moments(l);
        uint256 i =
            Guardians.clearFlag(l.g.keys, l.g.f, msg.sender, uint64(block.number), uint64(block.timestamp), S.DAY);
        S.noteHoldEnd(l, hb, ht, db, dt);
        // forge-lint: disable-next-line(unsafe-typecast)
        emit FlagCleared(msg.sender, uint8(i));
    }

    // ============================================================================================= recovery ==

    function _recoveryConfig() private view returns (RecoveryConfig memory) {
        if (_recoveryDelay == 0) revert RecoveryDisabled();
        return RecoveryConfig(
            _recoveryDelay, _recoveryThreshold, _recoveryCancelThreshold, _recoverySilence, _recoveryHoldPeriod
        );
    }

    /// @notice A guardian approves an emergency route replacement (§7.12); it opens once enough guardians approve
    /// the same proposal while the route is eligible. Calling again re-checks the eligibility.
    function approveRecovery(RecoveryProposal calldata p) external {
        RecoveryConfig memory c = _recoveryConfig();
        _delegate(S.layout(), abi.encodeCall(IBCAdminExec.approveRecovery, (msg.sender, abi.encode(p), c)));
    }

    /// @notice A guardian withdraws its approval, or votes to cancel the open proposal.
    function cancelRecovery() external {
        RecoveryConfig memory c = _recoveryConfig();
        _delegate(S.layout(), abi.encodeCall(IBCAdminExec.cancelRecovery, (msg.sender, c)));
    }

    /// @notice Executes the open proposal after its delay. Permissionless.
    function executeRecovery() external {
        RecoveryConfig memory c = _recoveryConfig();
        _delegate(S.layout(), abi.encodeCall(IBCAdminExec.executeRecovery, (c)));
    }

    // ================================================================================================ setup ==

    /// @notice Permissionless and self-checking: every authority is this contract's, the deployer holds no role, and
    /// the record is the launch's (IBCAdminExec.checkSetup's numbered checks; 40: this contract's own record).
    function finishSetup() external {
        S.Layout storage l = S.layout();
        if (l.setupDone) revert SetupAlreadyDone();
        _delegate(l, abi.encodeCall(IBCAdminExec.checkSetup, (deployer)));
        if (l.epoch != 1 || l.lastSeq != 0 || l.holds.length != 0 || l.conflictBlock != 0 || l.recovery.openedAt != 0) {
            revert SetupIncomplete(40);
        }
        l.setupDone = true;
        emit SetupDone();
    }

    // ============================================================================================== executor ==

    function _exec(S.Layout storage l) private view returns (address x) {
        x = l.exec;
        if (x.codehash != l.execHash) revert ForeignExec();
    }

    /// @notice Runs the executor's code as this contract; a revert there reverts here with its own reason.
    function _delegate(S.Layout storage l, bytes memory call) private returns (bytes memory) {
        (bool ok, bytes memory ret) = _exec(l).delegatecall(call);
        if (!ok) {
            // solhint-disable-next-line no-inline-assembly
            assembly ("memory-safe") {
                revert(add(ret, 32), mload(ret))
            }
        }
        return ret;
    }

    // ================================================================================================ views ==

    function epoch() external view returns (uint32) {
        return S.layout().epoch;
    }

    function lastSeq() external view returns (uint64) {
        return S.layout().lastSeq;
    }

    function govClient() external view returns (string memory) {
        return S.layout().govClient;
    }

    function lastRecordTime() external view returns (uint64) {
        return S.layout().lastRecordTime;
    }

    function decision(uint32 epoch_, uint64 seq) external view returns (Decision memory) {
        return S.layout().decisions[epoch_][seq];
    }

    function isTombstoned(uint32 epoch_, uint64 seq) external view returns (bool) {
        return S.isTombstoned(S.layout(), epoch_, seq);
    }

    function tombstones(uint32 epoch_) external view returns (uint64[2][] memory) {
        return S.layout().tombstones[epoch_];
    }

    function keys() external view returns (address[6] memory) {
        return S.layout().g.keys;
    }

    function flags() external view returns (IGuardians.Flag[6] memory) {
        S.Layout storage l = S.layout();
        return Guardians.flags(l.g.keys, l.g.f);
    }

    function hold() external view returns (IGuardians.Flag memory) {
        S.Layout storage l = S.layout();
        return Guardians.holdView(l.g.keys, l.g.f, uint64(block.timestamp), S.DAY);
    }

    function holds() external view returns (IGuardians.Hold[] memory) {
        return S.layout().holds;
    }

    function conflictBlock() external view returns (uint64) {
        return S.layout().conflictBlock;
    }

    function exec() external view returns (address, bytes32) {
        S.Layout storage l = S.layout();
        return (l.exec, l.execHash);
    }

    function setupDone() external view returns (bool) {
        return S.layout().setupDone;
    }

    function recoveryConfig() external view returns (RecoveryConfig memory) {
        return RecoveryConfig(
            _recoveryDelay, _recoveryThreshold, _recoveryCancelThreshold, _recoverySilence, _recoveryHoldPeriod
        );
    }

    /// @notice The open proposal (zero: none), when it opened, the seats voting to cancel it, and each guardian
    /// seat's approved proposal.
    function recovery()
        external
        view
        returns (bytes32 proposal, uint64 openedAt, uint8 cancels, bytes32[4] memory approved)
    {
        S.Recovery storage r = S.layout().recovery;
        return (r.proposal, r.openedAt, r.cancels, r.approved);
    }
}
