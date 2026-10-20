// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IIBCAdmin } from "../../src/interfaces/IIBCAdmin.sol";
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
/// unknown action, 3: another string offset, 4: a string longer than the answer).
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
        if (mode == 1) ret = abi.encode(uint256(0));
        else if (mode == 2) ret = abi.encode(uint256(7), uint256(0x40), uint256(0));
        else if (mode == 3) ret = abi.encode(uint256(0), uint256(0x20), uint256(0));
        else ret = abi.encode(uint256(0), uint256(0x40), uint256(1000));
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

    function test_kind9_deferredByAFlag() public {
        IBCAdminExec next = _good();
        uint64 seq = _decidePending(S.KIND_HANDOVER, P.handover(address(next), address(next).codehash, ""));
        vm.prank(W[0]);
        admin.setFlag();
        _skip(7 days);
        vm.expectRevert(IIBCAdmin.Deferred.selector);
        admin.execute(seq);
        assertEq(_state(seq), S.PENDING);
        vm.prank(W[0]);
        admin.clearFlag();
        admin.execute(seq);
        assertEq(_execOf(), address(next));
    }

    function test_kind9_deferredByAHold() public {
        IBCAdminExec next = _good();
        uint64 seq = _decidePending(S.KIND_HANDOVER, P.handover(address(next), address(next).codehash, ""));
        vm.prank(G[0]);
        admin.setFlag();
        vm.prank(G[1]);
        admin.setFlag();
        _skip(30 days);
        vm.expectRevert(IIBCAdmin.Deferred.selector);
        admin.execute(seq);
        assertEq(_state(seq), S.PENDING);
        assertEq(_execOf(), d.ibcAdminExec);
    }

    /// @notice A conflicting envelope at the hand-over's number flags IBCAdmin: the hand-over is deferred.
    function test_kind9_deferredByAConflict() public {
        IBCAdminExec next = _good();
        uint64 seq = _decidePending(S.KIND_HANDOVER, P.handover(address(next), address(next).codehash, ""));
        _recvGov(_env(seq, S.KIND_HANDOVER, P.handover(address(next), bytes32(uint256(1)), "")));
        assertTrue(admin.conflictBlock() != 0, "conflict");
        _skip(7 days);
        vm.expectRevert(IIBCAdmin.Deferred.selector);
        admin.execute(seq);
        assertEq(_state(seq), S.PENDING);
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
        for (uint256 mode = 1; mode <= 4; mode++) {
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
}
