// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IICS26RouterMsgs } from "@eureka/msgs/IICS26RouterMsgs.sol";
import { IICS02ClientMsgs } from "@eureka/msgs/IICS02ClientMsgs.sol";
import { IIBCAppCallbacks } from "@eureka/msgs/IIBCAppCallbacks.sol";

import { GnoVoucher } from "../../src/GnoVoucher.sol";
import { IIBCAdmin } from "../../src/interfaces/IIBCAdmin.sol";
import { IBCAdminStorage as S } from "../../src/admin/IBCAdminStorage.sol";
import { GovParams as P } from "../utils/GovParams.sol";
import { MockLightClient } from "../utils/MockLightClient.sol";
import { ControlsFixture } from "./ControlsFixture.sol";

/// @notice ADR §5.4's delivery protocol through the real router: ordering of recording (in order, buffered,
/// drained, beyond the window), duplicates and conflicts, cancellations anywhere with redispatch, epochs, and every
/// refusal as an error acknowledgement.
contract IBCAdminDeliveryTest is ControlsFixture {
    /// @notice A harmless 7-day decision: a kind 11 shortening of the quarantine to `q` seconds.
    function _shorten(uint64 seq, uint64 q) internal view returns (bytes memory) {
        return _env(seq, S.KIND_SETTINGS, P.settings(clientId, q));
    }

    function _assertAck(bytes memory ack, uint64 seq, uint8 status, uint8 redispatch) internal view {
        (uint32 e, uint64 s, uint8 st, uint8 r) = _govAck(ack);
        assertEq(e, admin.epoch(), "ack epoch");
        assertEq(s, seq, "ack seq");
        assertEq(st, status, "ack status");
        assertEq(r, redispatch, "ack redispatch");
    }

    function _state(uint64 seq) internal view returns (uint8) {
        return admin.decision(admin.epoch(), seq).state;
    }

    // ============================================================================================= ordering ==

    function test_inOrder_recorded_pending() public {
        bytes memory ack = _recvGov(_shorten(1, 1 days));
        _assertAck(ack, 1, S.STATUS_RECORDED, 0);
        assertEq(admin.lastSeq(), 1);
        assertEq(_state(1), S.PENDING);
        IIBCAdmin.Decision memory dec = admin.decision(1, 1);
        assertEq(dec.kind, S.KIND_SETTINGS);
        assertEq(dec.recordedTime, _now());
        assertEq(dec.hash, keccak256(_shorten(1, 1 days)));
    }

    function test_buffered_thenRecordedInOrderWhenTheGapFills() public {
        _assertAck(_recvGov(_shorten(3, 3)), 3, S.STATUS_BUFFERED, 0);
        _assertAck(_recvGov(_shorten(2, 2)), 2, S.STATUS_BUFFERED, 0);
        assertEq(admin.lastSeq(), 0);
        assertEq(_state(2), S.BUFFERED);
        _assertAck(_recvGov(_shorten(1, 1)), 1, S.STATUS_RECORDED, 0);
        assertEq(admin.lastSeq(), 3);
        assertEq(_state(2), S.PENDING);
        assertEq(_state(3), S.PENDING);
    }

    function test_drain_boundedPerCall_thenPermissionless() public {
        for (uint64 s = 2; s <= 12; s++) {
            _recvGov(_shorten(s, s));
        }
        _recvGov(_shorten(1, 1));
        assertEq(admin.lastSeq(), 1 + S.DRAIN, "at most DRAIN buffered per call");
        vm.prank(alice);
        assertEq(admin.drain(), 3);
        assertEq(admin.lastSeq(), 12);
        assertEq(admin.drain(), 0);
    }

    function test_window_lastPlusW_buffered_beyondErrorAck() public {
        _assertAck(_recvGov(_shorten(S.WINDOW, 1)), S.WINDOW, S.STATUS_BUFFERED, 0);
        bytes memory ack = _recvGov(_shorten(S.WINDOW + 1, 1));
        assertTrue(_isErrorAck(ack), "beyond the window: error ack, re-sent later");
        // the window moves with `last`
        _recvGov(_shorten(1, 1));
        _assertAck(_recvGov(_shorten(S.WINDOW + 1, 1)), S.WINDOW + 1, S.STATUS_BUFFERED, 0);
    }

    // ================================================================================ duplicate, conflict ==

    function test_duplicate_recordedAndBuffered() public {
        _recvGov(_shorten(1, 1));
        _assertAck(_recvGov(_shorten(1, 1)), 1, S.STATUS_DUPLICATE_RECORDED, 0);
        _recvGov(_shorten(5, 5));
        _assertAck(_recvGov(_shorten(5, 5)), 5, S.STATUS_DUPLICATE, 0);
        assertEq(admin.conflictBlock(), 0);
    }

    function test_conflict_keepsTheFirst_flagsAdmin() public {
        _recvGov(_shorten(1, 1));
        _assertAck(_recvGov(_shorten(1, 2)), 1, S.STATUS_CONFLICT, 0);
        assertEq(admin.conflictBlock(), vm.getBlockNumber());
        assertEq(admin.decision(1, 1).hash, keccak256(_shorten(1, 1)));
        // a buffered number too
        _recvGov(_shorten(4, 4));
        _assertAck(_recvGov(_shorten(4, 5)), 4, S.STATUS_CONFLICT, 0);
        assertEq(admin.decision(1, 4).hash, keccak256(_shorten(4, 4)));
        // the conflict's flag defers 7-day decisions
        _skip(7 days);
        vm.expectRevert(IIBCAdmin.Deferred.selector);
        admin.execute(1);
    }

    function test_conflict_clearedByLaterUnpause() public {
        _recvGov(_shorten(1, 1));
        _recvGov(_shorten(1, 2)); // conflict
        _skip(12);
        _recvGov(_env(2, S.KIND_UNPAUSE, P.unpause(2, "")));
        _skip(1 days);
        admin.execute(2);
        assertEq(admin.conflictBlock(), 0);
        _skip(6 days);
        admin.execute(1);
        assertEq(_state(1), S.EXECUTED);
        assertEq(ctl.quarantineSeconds(clientId), 1);
    }

    // ============================================================================================ cancels ==

    function test_cancel_inWindow_cancelsPending() public {
        _recvGov(_shorten(1, 1));
        _assertAck(_recvGov(_env(2, S.KIND_CANCEL, P.cancel1(1, 1))), 2, S.STATUS_RECORDED, 0);
        assertTrue(admin.isTombstoned(1, 1));
        assertEq(_state(2), S.EXECUTED);
        _skip(8 days);
        admin.execute(1);
        assertEq(_state(1), S.CANCELLED);
        assertEq(ctl.quarantineSeconds(clientId), 7 days, "never applied");
    }

    function test_cancel_beyondWindow_tombstonesAtOnce_redispatch() public {
        bytes memory cancelEnv = _env(100, S.KIND_CANCEL, P.cancel1(5, 7));
        _assertAck(_recvGov(cancelEnv), 100, S.STATUS_BUFFERED, 1);
        assertTrue(admin.isTombstoned(1, 5) && admin.isTombstoned(1, 7));
        assertFalse(admin.isTombstoned(1, 8));
        assertEq(admin.lastSeq(), 0);
        // the target arrives and is recorded cancelled
        for (uint64 s = 1; s <= 6; s++) {
            _recvGov(_shorten(s, s));
        }
        assertEq(_state(5), S.CANCELLED);
        assertEq(_state(6), S.CANCELLED);
        assertEq(_state(4), S.PENDING);
        // re-sent beyond the window again: tombstones re-applied (no-op), redispatch again
        _assertAck(_recvGov(cancelEnv), 100, S.STATUS_BUFFERED, 1);
        assertEq(admin.tombstones(1).length, 1);
    }

    function test_cancel_targetsAnyNumber_evenAboveItsOwn() public {
        // a forged decision 20 waits in the buffer while the honest ledger is at 10; the honest cancel 11 withdraws it
        for (uint64 s = 1; s <= 10; s++) {
            _recvGov(_shorten(s, s));
        }
        _recvGov(_shorten(20, 1));
        _recvGov(_env(11, S.KIND_CANCEL, P.cancel1(20, 20)));
        assertTrue(admin.isTombstoned(1, 20));
        for (uint64 s = 12; s <= 19; s++) {
            _recvGov(_shorten(s, s));
        }
        assertEq(_state(20), S.CANCELLED);
    }

    function test_cancel_beyondWindow_boundToItsHash() public {
        bytes memory first = _env(200, S.KIND_CANCEL, P.cancel1(5, 5));
        bytes memory other = _env(200, S.KIND_CANCEL, P.cancel1(6, 6));
        _assertAck(_recvGov(first), 200, S.STATUS_BUFFERED, 1);
        // another cancel at the same number: a conflict, its targets never tombstoned
        _assertAck(_recvGov(other), 200, S.STATUS_CONFLICT, 0);
        assertFalse(admin.isTombstoned(1, 6));
        assertTrue(admin.conflictBlock() != 0);
        // and once the window reaches it, other bytes at that number are a conflict too
        for (uint64 s = 1; s <= 150; s++) {
            _recvGov(_shorten(s, 1));
        }
        _assertAck(_recvGov(_env(200, S.KIND_SETTINGS, P.settings(clientId, 1))), 200, S.STATUS_CONFLICT, 0);
        // while the first bytes take their place in the sequence
        _assertAck(_recvGov(first), 200, S.STATUS_BUFFERED, 0);
        assertEq(admin.decision(1, 200).state, S.BUFFERED);
    }

    function test_cancel_rangesMergeAndStayBounded() public {
        // 70 disjoint single-number cancels, beyond the window: at most MAX_TOMBSTONES stored; only the targets
        // within the horizon (last + WINDOW, here 64) are tombstoned
        for (uint64 i = 0; i < 70; i++) {
            _recvGov(_env(1000 + i, S.KIND_CANCEL, P.cancel1(10 * i + 1, 10 * i + 1)));
        }
        assertLe(admin.tombstones(1).length, S.MAX_TOMBSTONES);
        for (uint64 i = 0; i < 70; i++) {
            assertEq(admin.isTombstoned(1, 10 * i + 1), 10 * i + 1 <= S.WINDOW);
        }
    }

    // ============================================================================================ horizon ==

    /// @notice Every stored tombstone ends at or before the current horizon `last + WINDOW`.
    function _assertUnderHorizon() internal view {
        uint64[2][] memory t = admin.tombstones(admin.epoch());
        for (uint256 i = 0; i < t.length; i++) {
            assertLe(t[i][1], admin.lastSeq() + S.WINDOW, "a tombstone past the horizon");
        }
    }

    /// @notice moul's review of gno#6375: a forged cancel `(1, 2^64-1)` beyond the window is clamped to the horizon
    /// read at its arrival; it burns the WINDOW numbers past the head (each acked 6 at its recording), and every
    /// later decision records and executes.
    function test_horizon_forgedFullRange_beyondWindow_burnsAtMostWindow() public {
        for (uint64 s = 1; s <= 5; s++) {
            _recvGov(_shorten(s, 1 days));
        }
        _assertAck(_recvGov(_env(1000, S.KIND_CANCEL, P.cancel1(1, type(uint64).max))), 1000, S.STATUS_BUFFERED, 1);
        uint64[2][] memory t = admin.tombstones(1);
        assertEq(t.length, 1);
        assertEq(t[0][0], 1);
        assertEq(t[0][1], 5 + S.WINDOW, "clamped to the horizon");
        for (uint64 s = 6; s <= 5 + S.WINDOW; s++) {
            _assertAck(_recvGov(_shorten(s, 2 days)), s, S.STATUS_CANCELLED, 0);
            assertEq(_state(s), S.CANCELLED);
        }
        uint64 next = 6 + S.WINDOW;
        assertFalse(admin.isTombstoned(1, next));
        _assertAck(_recvGov(_shorten(next, 3 days)), next, S.STATUS_RECORDED, 0);
        _assertAck(_recvGov(_shorten(next + 1, 4 days)), next + 1, S.STATUS_RECORDED, 0);
        _skip(7 days);
        admin.execute(next);
        admin.execute(next + 1);
        assertEq(_state(next), S.EXECUTED);
        assertEq(_state(next + 1), S.EXECUTED);
        assertEq(ctl.quarantineSeconds(clientId), 4 days);
        _assertUnderHorizon();
    }

    /// @notice The same forged range inside the window, at the next number: the cancel is recorded, its targets
    /// clamped to the horizon its arrival read.
    function test_horizon_forgedFullRange_inWindow_burnsAtMostWindow() public {
        _recvGov(_shorten(1, 1 days));
        _assertAck(_recvGov(_env(2, S.KIND_CANCEL, P.cancel1(1, type(uint64).max))), 2, S.STATUS_RECORDED, 0);
        assertEq(admin.tombstones(1)[0][1], 1 + S.WINDOW);
        for (uint64 s = 3; s <= 1 + S.WINDOW; s++) {
            _assertAck(_recvGov(_shorten(s, 2 days)), s, S.STATUS_CANCELLED, 0);
        }
        _assertAck(_recvGov(_shorten(2 + S.WINDOW, 3 days)), 2 + S.WINDOW, S.STATUS_RECORDED, 0);
        _skip(7 days);
        admin.execute(2 + S.WINDOW);
        assertEq(_state(2 + S.WINDOW), S.EXECUTED);
    }

    /// @notice Single-number cancels of the even numbers 2 to 128 fill the store (64 ranges), the head moving from 0
    /// to 64 between them; a forged `(130, 2^64-1)` then merges with its nearest stored range, `[128, 128]`, and
    /// the merged range ends at the horizon 130: the merge of a full store never reaches past it.
    function test_horizon_fullStoreMerge_staysUnderTheHorizon() public {
        uint64 cs = 10_000; // the cancels' own numbers, beyond the window
        for (uint64 base = 0; base < 128; base += 16) {
            if (base == 64) {
                // the head moves to 64: the evens recorded cancelled (ack 6), the odds pending
                for (uint64 s = 1; s <= 64; s++) {
                    _assertAck(_recvGov(_shorten(s, 1 days)), s, s % 2 == 0 ? S.STATUS_CANCELLED : S.STATUS_RECORDED, 0);
                }
            }
            P.Range[] memory r = new P.Range[](8);
            for (uint64 k = 0; k < 8; k++) {
                r[k] = P.Range(base + 2 * k + 2, base + 2 * k + 2);
            }
            _assertAck(_recvGov(_env(cs, S.KIND_CANCEL, P.cancel(r))), cs, S.STATUS_BUFFERED, 1);
            cs++;
            _assertUnderHorizon();
        }
        assertEq(admin.tombstones(1).length, S.MAX_TOMBSTONES, "the store is full");
        _recvGov(_shorten(65, 1 days));
        _assertAck(_recvGov(_shorten(66, 1 days)), 66, S.STATUS_CANCELLED, 0);
        assertEq(admin.lastSeq(), 66); // the horizon is 130
        _recvGov(_env(cs, S.KIND_CANCEL, P.cancel1(130, type(uint64).max)));
        assertEq(admin.tombstones(1).length, S.MAX_TOMBSTONES);
        _assertUnderHorizon();
        assertTrue(admin.isTombstoned(1, 129), "the gap's number dies with the merge");
        assertTrue(admin.isTombstoned(1, 130));
        assertFalse(admin.isTombstoned(1, 131));
        for (uint64 s = 67; s <= 130; s++) {
            _assertAck(
                _recvGov(_shorten(s, 1 days)), s, s % 2 == 0 || s >= 129 ? S.STATUS_CANCELLED : S.STATUS_RECORDED, 0
            );
        }
        _assertAck(_recvGov(_shorten(131, 2 days)), 131, S.STATUS_RECORDED, 0);
        _skip(7 days);
        admin.execute(131);
        assertEq(_state(131), S.EXECUTED);
    }

    /// @notice Codex's freeze of gno.land's known head: 2..64 delivered first (buffered, 2), then 1 (recorded, it
    /// drains 2..9), then 65. Every re-send of a recorded number answers 7, never the bare 3, so gno.land learns how
    /// far recording reached; a re-send of a number still buffered answers 3; a cancelled one 6; a spent one 7.
    function test_ack7_duplicateOfARecordedNumber() public {
        for (uint64 s = 2; s <= S.WINDOW; s++) {
            _assertAck(_recvGov(_shorten(s, s)), s, S.STATUS_BUFFERED, 0);
        }
        _assertAck(_recvGov(_shorten(1, 1)), 1, S.STATUS_RECORDED, 0);
        assertEq(admin.lastSeq(), 1 + S.DRAIN);
        _assertAck(_recvGov(_shorten(S.WINDOW + 1, 1)), S.WINDOW + 1, S.STATUS_BUFFERED, 0);
        uint64 last = admin.lastSeq();
        for (uint64 s = 1; s <= S.WINDOW + 1; s++) {
            uint64 q = s == S.WINDOW + 1 ? 1 : s;
            _assertAck(_recvGov(_shorten(s, q)), s, s <= last ? S.STATUS_DUPLICATE_RECORDED : S.STATUS_DUPLICATE, 0);
            last = admin.lastSeq(); // every delivery drains: the head moves while the re-sends go on
        }
        // a spent number (an unknown kind) and a cancelled one
        uint64 n = admin.lastSeq();
        while (admin.decision(1, n + 1).state == S.BUFFERED) {
            admin.drain();
            n = admin.lastSeq();
        }
        _assertAck(_recvGov(_env(n + 1, 99, "")), n + 1, S.STATUS_SPENT, 0);
        _assertAck(_recvGov(_env(n + 1, 99, "")), n + 1, S.STATUS_DUPLICATE_RECORDED, 0);
        _recvGov(_env(n + 2, S.KIND_CANCEL, P.cancel1(n + 3, n + 3)));
        _assertAck(_recvGov(_shorten(n + 3, 1)), n + 3, S.STATUS_CANCELLED, 0);
        _assertAck(_recvGov(_shorten(n + 3, 1)), n + 3, S.STATUS_CANCELLED, 0);
    }

    // ========================================================================================== ack 6 ==

    /// @notice A tombstoned decision is acked 6 at its recording (formerly 1, like an executed one), and so is every
    /// re-delivery of a decision in state CANCELLED (formerly 3): one recorded cancelled, one buffered and cancelled
    /// by a drain, one pending and cancelled at execution. Other duplicates stay 3.
    function test_ack6_atRecording_andOnADuplicateOfACancelledDecision() public {
        _assertAck(_recvGov(_env(1, S.KIND_CANCEL, P.cancel1(2, 2))), 1, S.STATUS_RECORDED, 0);
        _assertAck(_recvGov(_shorten(2, 1)), 2, S.STATUS_CANCELLED, 0);
        assertEq(_state(2), S.CANCELLED);
        _assertAck(_recvGov(_shorten(2, 1)), 2, S.STATUS_CANCELLED, 0);
        // buffered, then cancelled when a drain records it
        _assertAck(_recvGov(_shorten(5, 5)), 5, S.STATUS_BUFFERED, 0);
        _assertAck(_recvGov(_env(3, S.KIND_CANCEL, P.cancel1(5, 5))), 3, S.STATUS_RECORDED, 0);
        _assertAck(_recvGov(_shorten(5, 5)), 5, S.STATUS_DUPLICATE, 0); // still buffered
        _assertAck(_recvGov(_shorten(4, 4)), 4, S.STATUS_RECORDED, 0); // drains 5
        assertEq(_state(5), S.CANCELLED);
        _assertAck(_recvGov(_shorten(5, 5)), 5, S.STATUS_CANCELLED, 0);
        // pending, then cancelled at execution
        _recvGov(_shorten(6, 6));
        _recvGov(_env(7, S.KIND_CANCEL, P.cancel1(6, 6)));
        _assertAck(_recvGov(_shorten(6, 6)), 6, S.STATUS_DUPLICATE_RECORDED, 0); // pending: recorded
        _skip(7 days);
        admin.execute(6);
        assertEq(_state(6), S.CANCELLED);
        _assertAck(_recvGov(_shorten(6, 6)), 6, S.STATUS_CANCELLED, 0);
        // an executed cancel and an executed decision: duplicates of recorded numbers
        _assertAck(_recvGov(_env(7, S.KIND_CANCEL, P.cancel1(6, 6))), 7, S.STATUS_DUPLICATE_RECORDED, 0);
        admin.execute(4);
        _assertAck(_recvGov(_shorten(4, 4)), 4, S.STATUS_DUPLICATE_RECORDED, 0);
    }

    /// @notice An honest cancel of a buffered decision behaves as before: the decision is cancelled when it is
    /// recorded, its neighbours are not, and gno.land's redispatch of it learns it was cancelled (ack 6).
    function test_honestCancel_ofABufferedDecision_unchanged() public {
        for (uint64 s = 1; s <= 10; s++) {
            _recvGov(_shorten(s, 1 days));
        }
        _assertAck(_recvGov(_shorten(20, 2 days)), 20, S.STATUS_BUFFERED, 0);
        _assertAck(_recvGov(_env(11, S.KIND_CANCEL, P.cancel1(20, 20))), 11, S.STATUS_RECORDED, 0);
        uint64[2][] memory t = admin.tombstones(1);
        assertEq(t.length, 1);
        assertEq(t[0][0], 20);
        assertEq(t[0][1], 20);
        for (uint64 s = 12; s <= 19; s++) {
            _assertAck(_recvGov(_shorten(s, 3 days)), s, S.STATUS_RECORDED, 0);
        }
        assertEq(admin.lastSeq(), 20);
        assertEq(_state(20), S.CANCELLED);
        _assertAck(_recvGov(_shorten(20, 2 days)), 20, S.STATUS_CANCELLED, 0);
        _assertAck(_recvGov(_shorten(21, 4 days)), 21, S.STATUS_RECORDED, 0);
        _skip(7 days);
        admin.execute(19);
        admin.execute(21);
        assertEq(_state(19), S.EXECUTED);
        assertEq(_state(20), S.CANCELLED);
        assertEq(_state(21), S.EXECUTED);
        assertEq(ctl.quarantineSeconds(clientId), 4 days);
    }

    function test_cancel_badRanges_spent() public {
        _assertAck(_recvGov(_env(1, S.KIND_CANCEL, P.cancel1(5, 4))), 1, S.STATUS_SPENT, 0);
        _assertAck(_recvGov(_env(2, S.KIND_CANCEL, hex"00")), 2, S.STATUS_SPENT, 0);
        assertEq(admin.lastSeq(), 2);
        assertEq(admin.tombstones(1).length, 0);
        // a malformed cancel beyond the window is an ordinary refusal
        assertTrue(_isErrorAck(_recvGov(_env(500, S.KIND_CANCEL, hex"01"))));
    }

    // ================================================================================== spent at recording ==

    function test_unknownKind_recordedAndSpent() public {
        _assertAck(_recvGov(_env(1, 12, "")), 1, S.STATUS_SPENT, 0);
        _assertAck(_recvGov(_env(2, 0, "")), 2, S.STATUS_SPENT, 0);
        assertEq(admin.lastSeq(), 2);
        assertEq(_state(1), S.SPENT);
    }

    function test_badParams_spent_neverBlockTheSequence() public {
        _assertAck(_recvGov(_env(1, S.KIND_VOUCHER, hex"deadbeef")), 1, S.STATUS_SPENT, 0);
        _assertAck(_recvGov(_env(2, S.KIND_UNPAUSE, P.unpause(3, "x"))), 2, S.STATUS_SPENT, 0);
        _assertAck(_recvGov(_env(3, S.KIND_ROLE, P.role(true, 0, alice))), 3, S.STATUS_SPENT, 0);
        _assertAck(_recvGov(_shorten(4, 1)), 4, S.STATUS_RECORDED, 0);
    }

    function test_oversizeEnvelope_spent() public {
        bytes memory big = _env(1, S.KIND_SETTINGS, abi.encode(clientId, uint64(1), new bytes(1100)));
        assertGt(big.length, S.MAX_ENVELOPE);
        _assertAck(_recvGov(big), 1, S.STATUS_SPENT, 0);
    }

    // ============================================================================================ refusals ==

    function test_staleEpoch_errorAck() public {
        assertTrue(_isErrorAck(_recvGov(_envelope(2, 1, S.KIND_SETTINGS, P.settings(clientId, 1)))));
        assertTrue(_isErrorAck(_recvGov(_envelope(0, 1, S.KIND_SETTINGS, P.settings(clientId, 1)))));
        assertEq(admin.lastSeq(), 0);
    }

    function test_undecodable_errorAck() public {
        assertTrue(_isErrorAck(_recvGov(hex"01000000010000000000000001"))); // 13 bytes
        assertTrue(_isErrorAck(_recvGov(abi.encodePacked(uint8(2), uint32(1), uint64(1), uint8(11)))));
        assertTrue(_isErrorAck(_recvGov(_env(0, S.KIND_SETTINGS, P.settings(clientId, 1)))));
    }

    function test_wrongPayload_errorAck() public {
        IICS26RouterMsgs.Packet memory pkt = _govPacket(_shorten(1, 1));
        pkt.payloads[0].sourcePort = "transfer";
        assertTrue(_isErrorAck(_recv(pkt)));
        pkt = _govPacket(_shorten(1, 1));
        pkt.payloads[0].version = "ibcgov-2";
        assertTrue(_isErrorAck(_recv(pkt)));
        pkt = _govPacket(_shorten(1, 1));
        pkt.payloads[0].encoding = "application/json";
        assertTrue(_isErrorAck(_recv(pkt)));
        assertEq(admin.lastSeq(), 0);
    }

    function test_otherClient_errorAck() public {
        bytes[] memory prefix = new bytes[](1);
        prefix[0] = "";
        address other = address(new MockLightClient());
        vm.prank(address(admin));
        router.addClient("other-1", IICS02ClientMsgs.CounterpartyInfo("whatever-1", prefix), other);
        IICS26RouterMsgs.Packet memory pkt =
            _packetFromGno("other-1", "ibcgov", "ibcgov-1", "application/x-ibcgov", _shorten(1, 1));
        pkt.payloads[0].sourcePort = "gov";
        assertTrue(_isErrorAck(_recv(pkt)));
        assertEq(admin.lastSeq(), 0);
    }

    function test_onlyRouter_andNoSends() public {
        IIBCAppCallbacks.OnRecvPacketCallback memory m;
        vm.expectRevert(abi.encodeWithSelector(IIBCAdmin.NotRouter.selector, address(this)));
        admin.onRecvPacket(m);
        IIBCAppCallbacks.OnAcknowledgementPacketCallback memory a;
        vm.expectRevert(abi.encodeWithSelector(IIBCAdmin.NotRouter.selector, address(this)));
        admin.onAcknowledgementPacket(a);
        IIBCAppCallbacks.OnTimeoutPacketCallback memory t;
        vm.expectRevert(abi.encodeWithSelector(IIBCAdmin.NotRouter.selector, address(this)));
        admin.onTimeoutPacket(t);
        // from the router, an ack or timeout of anything but an epoch notice is ignored, never reverted
        vm.startPrank(address(router));
        admin.onAcknowledgementPacket(a);
        admin.onTimeoutPacket(t);
        vm.stopPrank();
    }

    /// @notice Governance is not quarantined: the route's quarantine stops token receives only.
    function test_governanceNotQuarantined() public {
        lc.setTransitionTime(uint64(_now()));
        assertTrue(_isErrorAck(_gnotIn(1, bob)));
        _assertAck(_recvGov(_shorten(1, 1)), 1, S.STATUS_RECORDED, 0);
    }

    /// @notice Random delivery orders of a run of decisions (duplicates, reorderings, beyond-window refusals
    /// re-sent): every number is recorded exactly once, in order, whatever the order of delivery.
    /// forge-config: default.fuzz.runs = 64
    function testFuzz_anyDeliveryOrder_recordsInOrder(uint256 seed) public {
        uint64 n = 80;
        uint64 delivered;
        bool[] memory recorded = new bool[](n + 1);
        for (uint256 step = 0; step < 150 && admin.lastSeq() < n; step++) {
            uint64 s = 1 + uint64(uint256(keccak256(abi.encode(seed, step))) % n);
            bytes memory ack = _recvGov(_shorten(s, s));
            if (!_isErrorAck(ack)) {
                (,, uint8 st,) = _govAck(ack);
                assertTrue(st != S.STATUS_CONFLICT && st != S.STATUS_SPENT);
                delivered++;
            } else {
                assertGt(s, admin.lastSeq() + S.WINDOW);
            }
            if (step % 7 == 0) admin.drain();
        }
        while (admin.lastSeq() < n) {
            uint64 s = admin.lastSeq() + 1;
            if (admin.decision(1, s).state == S.BUFFERED) admin.drain();
            else _recvGov(_shorten(s, s));
        }
        for (uint64 s = 1; s <= n; s++) {
            assertEq(_state(s), S.PENDING);
            recorded[s] = true;
        }
        assertEq(admin.conflictBlock(), 0);
        assertGt(delivered, 0);
    }
}
