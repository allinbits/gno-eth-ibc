// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Vm } from "forge-std/Vm.sol";
import { IICS26RouterMsgs } from "@eureka/msgs/IICS26RouterMsgs.sol";
import { IICS02ClientMsgs } from "@eureka/msgs/IICS02ClientMsgs.sol";
import { IICS26RouterErrors } from "@eureka/errors/IICS26RouterErrors.sol";
import { IIBCAdmin } from "../../src/interfaces/IIBCAdmin.sol";
import { IGnoICS20Controls } from "../../src/interfaces/IGnoICS20Controls.sol";
import { IBCAdminExec } from "../../src/admin/IBCAdminExec.sol";
import { IBCAdminStorage as S } from "../../src/admin/IBCAdminStorage.sol";
import { GovParams as P } from "../utils/GovParams.sol";
import { ControlsFixture } from "./ControlsFixture.sol";

/// @notice An executor bound as IBCAdmin's that reverts every call but `bindings()`: every kind it runs fails.
contract RevertingExec {
    address internal immutable r;
    address internal immutable am;
    address internal immutable t;

    constructor(address r_, address am_, address t_) {
        (r, am, t) = (r_, am_, t_);
    }

    function bindings() external view returns (address, address, address) {
        return (r, am, t);
    }

    fallback() external {
        revert("broken");
    }
}

/// @notice An executor bound as IBCAdmin's that spends every decision, at recording and at execution: under the
/// executor's own kind 9 it could never be replaced.
contract RefusingExec {
    address internal immutable r;
    address internal immutable am;
    address internal immutable t;

    constructor(address r_, address am_, address t_) {
        (r, am, t) = (r_, am_, t_);
    }

    function bindings() external view returns (address, address, address) {
        return (r, am, t);
    }

    function atRecording(uint8, uint64, bytes calldata, bool) external pure returns (uint8, string memory) {
        return (S.SPEND, "refused");
    }

    function run(uint8, uint64, bytes calldata, uint64) external pure returns (string memory) {
        return "refused";
    }
}

/// @notice An executor bound as IBCAdmin's whose every other answer is malformed, by `mode` (1: 32 bytes, 2: an
/// unknown action, 3: another string offset, 4: a string longer than the answer, 5: trailing data, 6: dirty padding,
/// 7: missing padding, 8: a spend with trailing data).
contract MalformedExec {
    address internal immutable r;
    address internal immutable am;
    address internal immutable t;
    uint256 internal immutable mode;

    constructor(address r_, address am_, address t_, uint256 mode_) {
        (r, am, t, mode) = (r_, am_, t_, mode_);
    }

    function bindings() external view returns (address, address, address) {
        return (r, am, t);
    }

    fallback() external {
        bytes memory ret;
        if (mode == 1) {
            ret = abi.encode(uint256(0));
        } else if (mode == 2) {
            ret = abi.encode(uint256(7), uint256(0x40), uint256(0));
        } else if (mode == 3) {
            ret = abi.encode(uint256(0), uint256(0x20), uint256(0));
        } else if (mode == 4) {
            ret = abi.encode(uint256(0), uint256(0x40), uint256(1000));
        } else if (mode == 5) {
            ret = abi.encodePacked(abi.encode(uint8(0), ""), uint256(0)); // trailing data
        } else if (mode == 6) {
            ret = abi.encode(uint8(0), "a");
            ret[ret.length - 1] = 0x01; // dirty padding
        } else if (mode == 7) {
            ret = abi.encodePacked(uint256(0), uint256(0x40), uint256(1), bytes1("a")); // missing padding
        } else {
            ret = abi.encode(uint256(2), uint256(64), uint256(0), uint256(123)); // a spend with trailing data
        }
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            return(add(ret, 32), mload(ret))
        }
    }
}

/// @notice An executor bound as IBCAdmin's that acts at recording (an IBCAdmin storage write, an event, a governed
/// call with IBCAdmin's authority), then answers by `mode`: 1 malformed (32 bytes), 2 oversize (MAX_ANSWER + 32
/// bytes), 3 huge (512 KiB), 4 burning nearly all its frame's gas and then answering the longest spend, 5 an
/// unknown action, 6
/// trailing data.
contract ActingExec {
    event Acted();

    address internal immutable r;
    address internal immutable am;
    address internal immutable t;
    uint256 internal immutable mode;
    string internal client;

    constructor(address r_, address am_, address t_, uint256 mode_, string memory client_) {
        (r, am, t, mode, client) = (r_, am_, t_, mode_, client_);
    }

    function bindings() external view returns (address, address, address) {
        return (r, am, t);
    }

    fallback() external {
        bytes memory ret;
        if (mode == 4) {
            // the longest answer the floor's margin must cover: a spend with a MAX_REASON-byte reason
            ret = abi.encode(uint8(2), string(new bytes(S.MAX_REASON)));
            while (gasleft() > 1500) { }
        } else {
            S.layout().conflictBlock = 77;
            emit Acted();
            IGnoICS20Controls(t).setQuarantine(client, 5 days);
            if (mode == 1) ret = abi.encode(uint256(0));
            else if (mode == 2) ret = new bytes(S.MAX_ANSWER + 32);
            else if (mode == 3) ret = new bytes(512 * 1024);
            else if (mode == 5) ret = abi.encode(uint256(7), uint256(0x40), uint256(0));
            else ret = abi.encodePacked(abi.encode(uint8(0), ""), uint256(0));
        }
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            return(add(ret, 32), mload(ret))
        }
    }
}

/// @notice `bindings()` answers IBCAdmin's own after burning `burn` gas, or another answer by `mode`.
contract OddBindings {
    address internal immutable r;
    address internal immutable am;
    address internal immutable t;
    uint256 internal immutable mode;
    uint256 internal immutable burn;

    constructor(address r_, address am_, address t_, uint256 mode_, uint256 burn_) {
        (r, am, t, mode, burn) = (r_, am_, t_, mode_, burn_);
    }

    function bindings() external view returns (address, address, address) {
        uint256 g = gasleft();
        while (g - gasleft() < burn) { }
        if (mode == 1) {
            // 128 bytes: the right three words and one more
            bytes memory ret = abi.encode(r, am, t, uint256(0));
            // solhint-disable-next-line no-inline-assembly
            assembly ("memory-safe") {
                return(add(ret, 32), 128)
            }
        }
        if (mode == 2) {
            // 64 bytes: two of the three
            bytes memory ret = abi.encode(r, am);
            // solhint-disable-next-line no-inline-assembly
            assembly ("memory-safe") {
                return(add(ret, 32), 64)
            }
        }
        if (mode == 3) revert("no");
        if (mode == 8) {
            // a revert carrying exactly the right 96 bytes
            bytes memory ret = abi.encode(r, am, t);
            // solhint-disable-next-line no-inline-assembly
            assembly ("memory-safe") {
                revert(add(ret, 32), 96)
            }
        }
        if (mode == 4) return (r, am, address(1));
        if (mode == 5) return (r, address(1), t);
        if (mode == 6) return (address(1), am, t);
        if (mode == 7) {
            // a dirty first word: the router's address with a high bit set
            bytes memory ret = abi.encode(uint256(uint160(r)) | (1 << 200), am, t);
            // solhint-disable-next-line no-inline-assembly
            assembly ("memory-safe") {
                return(add(ret, 32), 96)
            }
        }
        return (r, am, t);
    }
}

/// @notice Kind 9 is IBCAdmin's own (ADR pr6375 §5.4): recorded and executed without the installed executor, so a
/// broken executor is always replaceable; the same envelope, delay and deferral as every 7-day kind; the parameters
/// canonical with an empty migration call; the new code pinned and bound as IBCAdmin's.
contract HandOverTest is ControlsFixture {
    function _decide(uint8 kind, bytes memory params) internal returns (uint64 seq, uint8 status) {
        seq = admin.lastSeq() + 1;
        status = _status(_recvGov(_env(seq, kind, params)));
    }

    function _decidePending(uint8 kind, bytes memory params) internal returns (uint64 seq) {
        uint8 status;
        (seq, status) = _decide(kind, params);
        assertEq(status, S.STATUS_RECORDED, "recorded");
        assertEq(_state(seq), S.PENDING, "pending");
    }

    function _state(uint64 seq) internal view returns (uint8) {
        return admin.decision(admin.epoch(), seq).state;
    }

    function _execOf() internal view returns (address x) {
        (x,) = admin.exec();
    }

    function _good() internal returns (IBCAdminExec) {
        return new IBCAdminExec(address(router), d.accessManager, address(ics20));
    }

    function _odd(uint256 mode, uint256 burn) internal returns (address) {
        return address(new OddBindings(address(router), d.accessManager, address(ics20), mode, burn));
    }

    /// @notice Hands over to `x` through IBCAdmin's path; returns the decision's number.
    function _handOver(address x) internal returns (uint64 seq) {
        seq = _decidePending(S.KIND_HANDOVER, P.handover(x, x.codehash, ""));
        _skip(7 days);
        admin.execute(seq);
    }

    /// @notice Executes `seq` after its week, expecting it spent for `reason`, the pin unchanged.
    function _expectSpent(uint64 seq, string memory reason) internal {
        address before = _execOf();
        _skip(7 days);
        vm.expectEmit(true, true, false, true, address(admin));
        emit IIBCAdmin.DecisionSpent(admin.epoch(), seq, S.KIND_HANDOVER, reason);
        admin.execute(seq);
        assertEq(_state(seq), S.SPENT);
        assertEq(_execOf(), before, "pin unchanged");
    }

    /// @notice A broken executor (every call reverts) runs no kind; kind 9 still replaces it, and decisions run in
    /// the new one.
    function test_kind9_replacesAnExecutorThatRevertsEverything() public {
        address broken = address(new RevertingExec(address(router), d.accessManager, address(ics20)));
        _handOver(broken);
        assertEq(_execOf(), broken);
        // the broken executor spends every other kind at recording
        (, uint8 status) = _decide(S.KIND_SETTINGS, P.settings(clientId, 2 days));
        assertEq(status, S.STATUS_SPENT, "broken executor");
        IBCAdminExec next = _good();
        uint64 seq = _decidePending(S.KIND_HANDOVER, P.handover(address(next), address(next).codehash, ""));
        _skip(7 days);
        vm.expectEmit(address(admin));
        emit IIBCAdmin.ExecReplaced(address(next), address(next).codehash);
        vm.expectEmit(true, true, false, true, address(admin));
        emit IIBCAdmin.DecisionExecuted(admin.epoch(), seq, S.KIND_HANDOVER);
        admin.execute(seq);
        assertEq(_state(seq), S.EXECUTED);
        (address x, bytes32 h) = admin.exec();
        assertEq(x, address(next));
        assertEq(h, address(next).codehash);
        uint64 later = _decidePending(S.KIND_SETTINGS, P.settings(clientId, 2 days));
        _skip(7 days);
        admin.execute(later);
        assertEq(_state(later), S.EXECUTED);
        assertEq(ctl.quarantineSeconds(clientId), 2 days);
    }

    /// @notice An executor that refuses every decision, kind 9 included, at recording and at execution: replaced.
    function test_kind9_replacesAnExecutorThatRefusesKind9() public {
        address refusing = address(new RefusingExec(address(router), d.accessManager, address(ics20)));
        _handOver(refusing);
        assertEq(_execOf(), refusing);
        IBCAdminExec next = _good();
        uint64 seq = _handOver(address(next));
        assertEq(_state(seq), S.EXECUTED);
        assertEq(_execOf(), address(next));
    }

    /// @notice The installed executor's code changed under its pin: every other kind pends (ForeignExec), kind 9
    /// still records and executes.
    function test_kind9_replacesAForeignExecutor() public {
        vm.etch(d.ibcAdminExec, address(new RevertingExec(address(router), d.accessManager, address(ics20))).code);
        IBCAdminExec next = _good();
        uint64 seq = _handOver(address(next));
        assertEq(_state(seq), S.EXECUTED);
        assertEq(_execOf(), address(next));
    }

    // ------------------------------------------------------------------------------------------- recording --

    /// @notice A hand-over only moves the pin: a non-empty migration call is spent at recording.
    function test_kind9_nonEmptyMigration_spentAtRecording() public {
        IBCAdminExec next = _good();
        uint64 seq = admin.lastSeq() + 1;
        vm.expectEmit(true, true, false, true, address(admin));
        emit IIBCAdmin.DecisionSpent(admin.epoch(), seq, S.KIND_HANDOVER, "migration");
        bytes memory ack =
            _recvGov(_env(seq, S.KIND_HANDOVER, P.handover(address(next), address(next).codehash, hex"01020304")));
        assertEq(_status(ack), S.STATUS_SPENT);
        assertEq(_state(seq), S.SPENT);
        assertEq(_execOf(), d.ibcAdminExec);
    }

    function _spentParams(bytes memory params) internal {
        uint64 seq = admin.lastSeq() + 1;
        vm.expectEmit(true, true, false, true, address(admin));
        emit IIBCAdmin.DecisionSpent(admin.epoch(), seq, S.KIND_HANDOVER, "params");
        assertEq(_status(_recvGov(_env(seq, S.KIND_HANDOVER, params))), S.STATUS_SPENT);
    }

    /// @notice Anything but the canonical 128-byte encoding with a nonzero executor is spent at recording.
    function test_kind9_nonCanonicalParams_spentAtRecording() public {
        address x = address(_good());
        bytes32 h = x.codehash;
        _spentParams(P.handover(address(0), h, "")); // no executor
        _spentParams(abi.encodePacked(P.handover(x, h, ""), uint256(0))); // trailing word
        _spentParams(abi.encode(uint256(uint160(x)) | (1 << 160), h, uint256(0x60), uint256(0))); // dirty address
        _spentParams(abi.encode(x, h, uint256(0x40), uint256(0))); // another offset
        _spentParams(abi.encode(x, h, uint256(0x60))); // short
        _spentParams("");
        assertEq(_execOf(), d.ibcAdminExec);
    }

    // ------------------------------------------------------------------------------------------- execution --

    function test_kind9_wrongCodeHash_spent() public {
        IBCAdminExec next = _good();
        _expectSpent(_decidePending(S.KIND_HANDOVER, P.handover(address(next), bytes32(uint256(1)), "")), "codehash");
    }

    function test_kind9_noCode_spent() public {
        address eoa = makeAddr("no code");
        _expectSpent(_decidePending(S.KIND_HANDOVER, P.handover(eoa, eoa.codehash, "")), "codehash");
    }

    /// @notice An EIP-7702 delegation designator to a good executor is refused, whatever it would answer.
    function test_kind9_7702Designator_spent() public {
        IBCAdminExec next = _good();
        address eoa = makeAddr("delegating eoa");
        vm.etch(eoa, abi.encodePacked(hex"ef0100", address(next)));
        _expectSpent(_decidePending(S.KIND_HANDOVER, P.handover(eoa, eoa.codehash, "")), "codehash");
    }

    function test_kind9_wrongBindings_spent() public {
        for (uint256 mode = 1; mode <= 8; mode++) {
            address x = _odd(mode, 0);
            _expectSpent(_decidePending(S.KIND_HANDOVER, P.handover(x, x.codehash, "")), "bindings");
        }
        IBCAdminExec foreign = new IBCAdminExec(address(router), d.accessManager, address(usdc));
        _expectSpent(
            _decidePending(S.KIND_HANDOVER, P.handover(address(foreign), address(foreign).codehash, "")), "bindings"
        );
    }

    /// @notice A `bindings()` past BIND_GAS fails the probe and spends the decision.
    function test_kind9_bindingsOverBudget_spent() public {
        address x = _odd(0, S.BIND_GAS + 1);
        _expectSpent(_decidePending(S.KIND_HANDOVER, P.handover(x, x.codehash, "")), "bindings");
    }

    /// @notice A caller sending too little gas for the probe is refused before it: the decision pends, never spent.
    function test_kind9_starvedCaller_pends() public {
        address x = _odd(0, 90_000);
        uint64 seq = _decidePending(S.KIND_HANDOVER, P.handover(x, x.codehash, ""));
        _skip(7 days);
        vm.expectRevert(IIBCAdmin.CallStarved.selector);
        admin.execute{ gas: 115_000 }(seq);
        assertEq(_state(seq), S.PENDING);
        admin.execute(seq);
        assertEq(_state(seq), S.EXECUTED);
        assertEq(_execOf(), x);
    }

    // ------------------------------------------------------------------------------------------ governance --

    function test_kind9_waitsItsWeek() public {
        IBCAdminExec next = _good();
        uint64 seq = _decidePending(S.KIND_HANDOVER, P.handover(address(next), address(next).codehash, ""));
        uint64 due = admin.decision(admin.epoch(), seq).recordedTime + 7 days;
        _skip(7 days - 1);
        vm.expectRevert(abi.encodeWithSelector(IIBCAdmin.NotMature.selector, due));
        admin.execute(seq);
        _skip(1);
        admin.execute(seq);
        assertEq(_execOf(), address(next));
    }

    // ----------------------------------------------- deferral: flags and holds, each no longer than 21 days --

    function _k9() internal returns (uint64 seq, address next) {
        next = address(_good());
        seq = _decidePending(S.KIND_HANDOVER, P.handover(next, next.codehash, ""));
    }

    function _flag(address key) internal {
        vm.prank(key);
        admin.setFlag();
    }

    function _unflag(address key) internal {
        vm.prank(key);
        admin.clearFlag();
    }

    function _hold() internal {
        _flag(G[0]);
        _flag(G[1]);
    }

    /// @notice `execute` before `landsAt` reverts NotMature(landsAt); at `landsAt` it executes and installs `next`.
    function _landsAt(uint64 seq, address next, uint256 landsAt) internal {
        vm.warp(landsAt - 1);
        vm.expectRevert(abi.encodeWithSelector(IIBCAdmin.NotMature.selector, landsAt));
        admin.execute(seq);
        vm.warp(landsAt);
        admin.execute(seq);
        assertEq(_state(seq), S.EXECUTED);
        assertEq(_execOf(), next);
    }

    /// @notice A lone flag defers a hand-over from its start plus 21 days, no longer: the first execution attempt
    /// once due pins the anchor and returns (pending; a revert would undo the pin).
    function test_kind9_loneFlag_defersUntilItsStartPlus21Days() public {
        uint256 t0 = _now();
        (uint64 seq, address next) = _k9();
        vm.warp(t0 + 1 days);
        _flag(W[0]);
        vm.warp(t0 + 7 days);
        vm.expectEmit(true, true, false, true, address(admin));
        emit IIBCAdmin.ReplacementAnchored(admin.epoch(), seq, uint64(t0 + 22 days));
        admin.execute(seq); // pins the flag's start
        assertEq(_state(seq), S.PENDING);
        _landsAt(seq, next, t0 + 22 days);
    }

    /// @notice The deadlock it resolves: a watch key flags IBCAdmin and becomes unavailable (its flag never clears),
    /// the executor breaks, recovery is disabled. The hand-over still lands 21 days after the flag.
    function test_kind9_unavailableFlaggingKey_brokenExecutor_landsAfter21Days() public {
        uint256 t0 = _now();
        (, uint64 openedAt,,) = admin.recovery();
        assertEq(openedAt, 0);
        vm.expectRevert(IIBCAdmin.RecoveryDisabled.selector);
        admin.executeRecovery();
        _flag(W[1]); // and W[1] is never heard from again
        vm.etch(d.ibcAdminExec, address(new RevertingExec(address(router), d.accessManager, address(ics20))).code);
        (uint64 seq, address next) = _k9();
        vm.warp(t0 + 7 days);
        admin.execute(seq);
        _landsAt(seq, next, t0 + 21 days);
        assertTrue(admin.flags()[5].blockNumber != 0, "W[1]'s flag still stands");
    }

    /// @notice A flag standing since long before the hand-over was due no longer defers it: it lands when due.
    function test_kind9_flagOlderThan21DaysAtDue_landsWhenDue() public {
        uint256 t0 = _now();
        _flag(W[0]);
        vm.warp(t0 + 20 days);
        (uint64 seq, address next) = _k9();
        vm.warp(t0 + 27 days);
        admin.execute(seq);
        assertEq(_state(seq), S.EXECUTED);
        assertEq(_execOf(), next);
    }

    /// @notice A fresh flag set after the hand-over was due defers it from that flag's start plus 21 days.
    function test_kind9_freshFlagAfterDue_defers() public {
        uint256 t0 = _now();
        (uint64 seq, address next) = _k9();
        vm.warp(t0 + 10 days);
        _flag(W[0]);
        vm.warp(t0 + 11 days);
        admin.execute(seq);
        assertEq(_state(seq), S.PENDING);
        _landsAt(seq, next, t0 + 31 days);
    }

    /// @notice Cycling flags never extends the deferral: the anchor is pinned once and never reset, whatever flags
    /// are cleared and set (by the same key or others) afterwards.
    function test_kind9_flagCycling_neverResetsTheAnchor() public {
        uint256 t0 = _now();
        (uint64 seq, address next) = _k9();
        vm.warp(t0 + 8 days);
        _flag(W[0]);
        vm.warp(t0 + 9 days);
        admin.execute(seq); // pins day 8
        vm.warp(t0 + 10 days);
        _unflag(W[0]);
        vm.warp(t0 + 12 days);
        _flag(W[1]);
        vm.warp(t0 + 15 days);
        _flag(W[0]);
        _flag(W[0]); // a re-flag moves its own start, never the pinned anchor
        vm.warp(t0 + 20 days);
        vm.expectRevert(abi.encodeWithSelector(IIBCAdmin.NotMature.selector, t0 + 29 days));
        admin.execute(seq);
        _landsAt(seq, next, t0 + 29 days);
    }

    /// @notice A hold and an earlier lone flag together: each deferral applies, the later one wins (the hold's).
    function test_kind9_holdAndFlag_bothApply() public {
        uint256 t0 = _now();
        (uint64 seq, address next) = _k9();
        vm.warp(t0 + 1 days);
        _flag(G[0]); // a lone flag from day 1
        vm.warp(t0 + 3 days);
        _flag(G[1]); // a hold from day 3
        vm.warp(t0 + 7 days);
        admin.execute(seq); // pins both: the flag's day 1, the hold's day 3
        assertEq(admin.replacementAnchor(admin.epoch(), seq), t0 + 3 days);
        _landsAt(seq, next, t0 + 24 days);
    }

    /// @notice A conflict's flag has no start of its own: it counts from the first attempt once due.
    function test_kind9_conflict_defersFromFirstSightPlus21Days() public {
        uint256 t0 = _now();
        (uint64 seq, address next) = _k9();
        _recvGov(_env(seq, S.KIND_HANDOVER, P.handover(next, bytes32(uint256(1)), "")));
        assertTrue(admin.conflictBlock() != 0, "conflict");
        vm.warp(t0 + 7 days);
        admin.execute(seq);
        assertEq(_state(seq), S.PENDING);
        _landsAt(seq, next, t0 + 28 days);
    }

    // kind 3's hold anchor cases, for kind 9 (the same rule, IBCAdminStorage.anchor, the shared `seatAnchor`)

    function test_kind9_anchor_holdBeforeDueNeverCounts() public {
        uint256 t0 = _now();
        (uint64 seq, address next) = _k9();
        vm.warp(t0 + 1 days);
        _hold(); // days 1 to 3
        vm.warp(t0 + 2 days);
        _unflag(G[1]);
        vm.warp(t0 + 20 days);
        assertEq(admin.hold().blockNumber, 0, "the first hold ended");
        _flag(G[1]); // the second hold, from day 20
        vm.warp(t0 + 22 days);
        admin.execute(seq); // pins day 20
        assertEq(admin.replacementAnchor(admin.epoch(), seq), t0 + 20 days);
        _landsAt(seq, next, t0 + 41 days);
    }

    function test_kind9_anchor_clearAndReflagCycles_neverReset() public {
        uint256 t0 = _now();
        (uint64 seq, address next) = _k9();
        vm.warp(t0 + 8 days);
        _hold();
        vm.warp(t0 + 9 days);
        admin.execute(seq);
        uint256 floor = t0 + 8 days + 21 days;
        assertEq(admin.replacementAnchor(admin.epoch(), seq), t0 + 8 days);
        for (uint256 k = 0; k < 3; k++) {
            _unflag(G[1]);
            _skip(1 days + 1); // the grace passes: the hold ends
            assertEq(admin.hold().blockNumber, 0);
            _flag(G[1]); // a fresh hold
            vm.expectRevert(abi.encodeWithSelector(IIBCAdmin.NotMature.selector, floor));
            admin.execute(seq);
        }
        _landsAt(seq, next, floor);
    }

    function test_kind9_anchor_unobservedHoldCounts() public {
        uint256 t0 = _now();
        (uint64 seq, address next) = _k9();
        vm.warp(t0 + 8 days);
        _hold();
        vm.warp(t0 + 9 days);
        _unflag(G[1]);
        vm.warp(t0 + 15 days);
        _flag(G[1]);
        vm.warp(t0 + 16 days);
        admin.execute(seq);
        assertEq(admin.replacementAnchor(admin.epoch(), seq), t0 + 8 days);
        _landsAt(seq, next, t0 + 29 days);
    }

    function test_kind9_anchor_holdEndingExactlyAtDue_neverCounts() public {
        uint256 t0 = _now();
        (uint64 seq, address next) = _k9();
        vm.warp(t0 + 1 days);
        _hold();
        vm.warp(t0 + 6 days);
        _unflag(G[1]); // the dip: the hold ends 24 hours later, exactly on day 7
        vm.warp(t0 + 20 days);
        _flag(G[1]);
        assertEq(admin.holds()[0].end, t0 + 7 days);
        vm.warp(t0 + 22 days);
        admin.execute(seq);
        assertEq(admin.replacementAnchor(admin.epoch(), seq), t0 + 20 days);
        _landsAt(seq, next, t0 + 41 days);
    }

    function test_kind9_anchor_compressedHistory_neverEarlier() public {
        uint256 t0 = _now();
        (uint64 seq, address next) = _k9();
        _flag(G[0]);
        uint256[9] memory starts = [uint256(1), 20, 22, 24, 26, 28, 30, 32, 34];
        for (uint256 k = 0; k < starts.length; k++) {
            vm.warp(t0 + starts[k] * 1 days);
            _flag(G[1]);
            vm.warp(t0 + starts[k] * 1 days + 1 hours);
            _unflag(G[1]);
        }
        vm.warp(t0 + 36 days);
        _flag(G[1]);
        assertTrue(admin.holds()[0].merged, "compressed");
        admin.execute(seq); // pins
        uint64 anchor = admin.replacementAnchor(admin.epoch(), seq);
        assertGe(anchor, t0 + 20 days, "never anchored on the merged interval");
        _landsAt(seq, next, uint256(anchor) + 21 days);
    }

    function test_kind9_cancelledByKind1() public {
        IBCAdminExec next = _good();
        uint64 seq = _decidePending(S.KIND_HANDOVER, P.handover(address(next), address(next).codehash, ""));
        _recvGov(_env(seq + 1, S.KIND_CANCEL, P.cancel1(seq, seq)));
        _skip(7 days);
        admin.execute(seq);
        assertEq(_state(seq), S.CANCELLED);
        assertEq(_execOf(), d.ibcAdminExec);
    }

    // ------------------------------------------------------------------- a broken executor never blocks kind 9 --

    /// @notice Delivers `kind` at `seq` and returns the ack's status.
    function _at(uint64 seq, uint8 kind, bytes memory params) internal returns (uint8) {
        return _status(_recvGov(_env(seq, kind, params)));
    }

    /// @notice A decision buffered behind the kind 9: the kind 9's delivery records it and stops the drain at the
    /// buffered decision the broken executor cannot answer (nothing recorded, nothing spent); kind 9 replaces the
    /// executor, and the buffered decision then drains through the new one.
    function _bufferedBehindKind9() internal {
        uint64 s = admin.lastSeq();
        assertEq(_at(s + 2, S.KIND_SETTINGS, P.settings(clientId, 2 days)), S.STATUS_BUFFERED);
        IBCAdminExec next = _good();
        assertEq(_at(s + 1, S.KIND_HANDOVER, P.handover(address(next), address(next).codehash, "")), S.STATUS_RECORDED);
        assertEq(admin.lastSeq(), s + 1, "the kind 9 recorded");
        assertEq(_state(s + 2), S.BUFFERED, "the decision behind it stays buffered");
        assertEq(admin.decision(admin.epoch(), s + 2).recordedTime, 0, "nothing recorded");
        assertEq(admin.decision(admin.epoch(), s + 2).recordedBlock, 0, "nothing recorded");
        assertEq(admin.drain(), 0, "a drain stops at it");
        assertEq(_state(s + 2), S.BUFFERED);
        _skip(7 days);
        admin.execute(s + 1);
        (address x,) = admin.exec();
        assertEq(x, address(next), "replaced");
        assertEq(admin.drain(), 1, "drains through the new executor");
        assertEq(_state(s + 2), S.PENDING);
        _skip(7 days);
        admin.execute(s + 2);
        assertEq(ctl.quarantineSeconds(clientId), 2 days);
    }

    function test_kind9_bufferedBehind_foreignExecutor() public {
        vm.etch(d.ibcAdminExec, address(new RevertingExec(address(router), d.accessManager, address(ics20))).code);
        _bufferedBehindKind9();
    }

    function test_kind9_bufferedBehind_malformedExecutor() public {
        for (uint256 mode = 1; mode <= 8; mode++) {
            uint256 snap = vm.snapshotState();
            _handOver(address(new MalformedExec(address(router), d.accessManager, address(ics20), mode)));
            _bufferedBehindKind9();
            vm.revertToState(snap);
        }
    }

    /// @notice A delivered decision the broken executor cannot answer is acknowledged buffered, never spent; a kind 9
    /// behind it waits, so gno.land cancels the stuck decision (the tombstones apply on arrival and nothing in the
    /// delivery reverts), the kind 9 records, and the replacement follows.
    function test_kind9_haltedDecisionAhead_cancelledThenReplaced() public {
        vm.etch(d.ibcAdminExec, address(new RevertingExec(address(router), d.accessManager, address(ics20))).code);
        uint64 s = admin.lastSeq();
        _skip(1 hours);
        uint64 silenceFrom = admin.lastRecordTime();
        assertEq(_at(s + 1, S.KIND_SETTINGS, P.settings(clientId, 2 days)), S.STATUS_BUFFERED, "halted, buffered");
        assertEq(admin.lastSeq(), s);
        assertEq(_state(s + 1), S.BUFFERED);
        assertEq(admin.lastRecordTime(), silenceFrom, "the channel's silence unchanged");
        assertEq(admin.decision(admin.epoch(), s + 1).recordedBlock, 0);
        IBCAdminExec next = _good();
        assertEq(_at(s + 2, S.KIND_HANDOVER, P.handover(address(next), address(next).codehash, "")), S.STATUS_BUFFERED);
        _at(s + 3, S.KIND_CANCEL, P.cancel1(s + 1, s + 1));
        assertEq(_state(s + 1), S.CANCELLED);
        assertEq(_state(s + 2), S.PENDING, "the kind 9 recorded");
        assertEq(admin.lastSeq(), s + 3);
        _skip(7 days);
        admin.execute(s + 2);
        (address x,) = admin.exec();
        assertEq(x, address(next));
    }

    /// @notice An executor that reverts at recording answers like malformed parameters: the decision behind the kind
    /// 9 is spent (a revert is indistinguishable from undecodable parameters), and the kind 9 records and executes.
    function test_kind9_bufferedBehind_revertingExecutor_spent() public {
        _handOver(address(new RevertingExec(address(router), d.accessManager, address(ics20))));
        uint64 s = admin.lastSeq();
        _at(s + 2, S.KIND_SETTINGS, P.settings(clientId, 2 days));
        IBCAdminExec next = _good();
        assertEq(_at(s + 1, S.KIND_HANDOVER, P.handover(address(next), address(next).codehash, "")), S.STATUS_RECORDED);
        assertEq(_state(s + 2), S.SPENT);
        _skip(7 days);
        admin.execute(s + 1);
        (address x,) = admin.exec();
        assertEq(x, address(next));
    }

    // ------------------------------------------------------------------------------------- recording starvation --

    function _recvWithGas(bytes memory envelope, uint256 gas) internal returns (bool ok) {
        (ok,) = address(router).call{ gas: gas }(
            abi.encodeCall(
                router.recvPacket,
                (IICS26RouterMsgs.MsgRecvPacket(_govPacket(envelope), "", IICS02ClientMsgs.Height(0, 1)))
            )
        );
    }

    /// @notice A delivery with too little gas to record its decision reverts whole (no data: the router keeps no
    /// receipt and writes no ack), so a starving relayer consumes nothing: the same packet records when relayed
    /// again with enough gas.
    function test_starvedDelivery_noReceipt_samePacketRecordsOnRetry() public {
        uint64 s = admin.lastSeq() + 1;
        bytes memory env = _env(s, S.KIND_SETTINGS, P.settings(clientId, 2 days));
        IICS26RouterMsgs.MsgRecvPacket memory m =
            IICS26RouterMsgs.MsgRecvPacket(_govPacket(env), "", IICS02ClientMsgs.Height(0, 1));
        vm.expectRevert(IICS26RouterErrors.IBCFailedCallback.selector);
        router.recvPacket{ gas: 700_000 }(m);
        assertEq(_state(s), S.NONE);
        assertEq(_status(_recvGov(env)), S.STATUS_RECORDED, "the same packet, relayed again");
        assertEq(_state(s), S.PENDING);
    }

    /// @notice A drain short of gas stops without undoing what the delivery recorded: a kind 9 survives, and the
    /// decision after it stays buffered for `drain()`.
    function test_starvedDrain_keepsTheKind9() public {
        uint64 s = admin.lastSeq();
        _recvGov(_env(s + 2, S.KIND_SETTINGS, P.settings(clientId, 2 days)));
        IBCAdminExec next = _good();
        assertTrue(
            _recvWithGas(_env(s + 1, S.KIND_HANDOVER, P.handover(address(next), address(next).codehash, "")), 700_000)
        );
        assertEq(_state(s + 1), S.PENDING, "the kind 9 recorded");
        assertEq(_state(s + 2), S.BUFFERED, "the drain stopped");
        assertEq(admin.drain(), 1);
        assertEq(_state(s + 2), S.PENDING);
    }

    /// @notice Only standing flags anchor: a flag whose key was replaced (kind 3) keeps its stored time but no longer
    /// stands, and never counts.
    function test_kind9_flagOfAReplacedKey_neverAnchors() public {
        uint256 t0 = _now();
        uint64 seats = _decidePending(S.KIND_SEATS, P.seat1(4, makeAddr("fresh watch")));
        vm.warp(t0 + 1 days);
        _flag(W[0]); // seat 4
        vm.warp(t0 + 5 days);
        (uint64 seq, address next) = _k9(); // due on day 12
        vm.warp(t0 + 7 days);
        admin.execute(seats); // W[0] replaced: its flag no longer stands
        assertEq(_state(seats), S.EXECUTED);
        vm.warp(t0 + 10 days);
        _flag(W[1]);
        vm.warp(t0 + 12 days);
        admin.execute(seq); // anchors at W[1]'s day 10, never W[0]'s day 1
        _landsAt(seq, next, t0 + 31 days);
    }

    /// @notice `drain()` short of gas for the executor's frame stops at once, nothing recorded or counted.
    function test_starvedDrain_stopsAtOnce() public {
        uint64 s = admin.lastSeq();
        _recvGov(_env(s + 2, S.KIND_SETTINGS, P.settings(clientId, 2 days)));
        IBCAdminExec next = _good();
        // the kind 9 records; its drain starves, leaving s + 2 buffered next
        assertTrue(
            _recvWithGas(_env(s + 1, S.KIND_HANDOVER, P.handover(address(next), address(next).codehash, "")), 700_000)
        );
        assertEq(_state(s + 2), S.BUFFERED);
        assertEq(admin.drain{ gas: 600_000 }(), 0, "starved: stops at once");
        assertEq(_state(s + 2), S.BUFFERED);
        assertEq(admin.drain(), 1);
        assertEq(_state(s + 2), S.PENDING);
    }

    // --------------------------------------------------- a halted answer is undone; the answer's copy is bounded --

    function _acting(uint256 mode) internal returns (address x) {
        x = address(new ActingExec(address(router), d.accessManager, address(ics20), mode, clientId));
        _handOver(x);
        assertEq(_execOf(), x);
    }

    /// @notice An executor that acts at recording (a storage write, an event, a governed call) and then answers
    /// malformed or oversize: the answer halts the decision and everything the executor did is undone with its frame;
    /// the decision stays buffered and a cancel then records it as cancelled.
    function test_haltedAnswer_undoesTheExecutorsEffects() public {
        uint8[4] memory modes = [1, 2, 5, 6];
        for (uint256 k = 0; k < modes.length; k++) {
            uint256 snap = vm.snapshotState();
            _acting(modes[k]);
            uint64 q = ctl.quarantineSeconds(clientId);
            uint64 s = admin.lastSeq();
            vm.recordLogs();
            assertEq(_at(s + 1, S.KIND_SETTINGS, P.settings(clientId, 2 days)), S.STATUS_BUFFERED, "halted");
            Vm.Log[] memory logs = vm.getRecordedLogs();
            for (uint256 i = 0; i < logs.length; i++) {
                assertTrue(logs[i].topics[0] != ActingExec.Acted.selector, "its event undone");
            }
            assertEq(admin.conflictBlock(), 0, "its storage write undone");
            assertEq(ctl.quarantineSeconds(clientId), q, "its governed call undone");
            assertEq(_state(s + 1), S.BUFFERED);
            _at(s + 2, S.KIND_CANCEL, P.cancel1(s + 1, s + 1));
            assertEq(_state(s + 1), S.CANCELLED);
            assertEq(admin.lastSeq(), s + 2);
            vm.revertToState(snap);
        }
    }

    /// @notice A huge answer is never copied: it halts, and a kind 9 recorded ahead of it in the same delivery stands
    /// (copying it would cost more than the floor's margin and revert the whole delivery).
    function test_hugeAnswer_halts_kind9Ahead_stands() public {
        _acting(3);
        uint64 s = admin.lastSeq();
        _at(s + 2, S.KIND_SETTINGS, P.settings(clientId, 2 days));
        IBCAdminExec next = _good();
        assertTrue(
            _recvWithGas(_env(s + 1, S.KIND_HANDOVER, P.handover(address(next), address(next).codehash, "")), 1_500_000)
        );
        assertEq(_state(s + 1), S.PENDING, "the kind 9 recorded");
        assertEq(_state(s + 2), S.BUFFERED, "the huge answer halted");
        assertEq(admin.conflictBlock(), 0);
    }

    /// @notice An executor burning nearly all its frame: whatever gas a relayer sends, the delivery either stops the
    /// drain before the executor (starved) or completes the recording within the floor's margin; it never runs out
    /// of gas after the floor, so a kind 9 recorded ahead of it always stands.
    function test_gasBurningAnswer_kind9Ahead_alwaysStands() public {
        _acting(4);
        uint64 s = admin.lastSeq();
        _at(s + 2, S.KIND_SETTINGS, P.settings(clientId, 2 days));
        IBCAdminExec next = _good();
        bytes memory env = _env(s + 1, S.KIND_HANDOVER, P.handover(address(next), address(next).codehash, ""));
        uint256 recorded;
        for (uint256 gas = 1_000_000; gas <= 1_400_000; gas += 1999) {
            uint256 snap = vm.snapshotState();
            assertTrue(_recvWithGas(env, gas), "the delivery completes");
            assertEq(_state(s + 1), S.PENDING, "the kind 9 stands");
            if (_state(s + 2) == S.SPENT) recorded++;
            vm.revertToState(snap);
        }
        assertGt(recorded, 0, "the burning executor's answer recorded at some gas");
    }
}
