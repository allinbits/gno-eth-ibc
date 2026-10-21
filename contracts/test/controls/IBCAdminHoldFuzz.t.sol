// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IGuardians } from "../../src/interfaces/IGuardians.sol";
import { IBCAdminStorage as S } from "../../src/admin/IBCAdminStorage.sol";
import { GovParams as P } from "../utils/GovParams.sol";
import { ControlsFixture } from "./ControlsFixture.sol";

/// @notice The hold state machine as it gates execution (§6.6, §6.7, §7.4): random flags, clears and clock steps by
/// the six keys, with a 7-day decision and a guardian replacement waiting. A 7-day decision executes exactly when it
/// has matured and no flag or hold stands; the replacement never before its 7 days, and under a hold never before
/// its anchor plus 21 days: the start of the first hold standing once it was due, pinned, never reset by later holds.
contract IBCAdminHoldFuzzTest is ControlsFixture {
    /// forge-config: default.fuzz.runs = 256
    function testFuzz_holdStateMachine(uint256 seed) public {
        uint64 settings = admin.lastSeq() + 1;
        _recvGov(_env(settings, S.KIND_SETTINGS, P.settings(clientId, 1 days)));
        uint64 seats = settings + 1;
        _recvGov(_env(seats, S.KIND_SEATS, P.seat1(5, makeAddr("fresh watch"))));
        uint64 recorded = admin.decision(1, settings).recordedTime;
        address[6] memory keys = [G[0], G[1], G[2], G[3], W[0], W[1]];
        bool settingsDone;
        bool seatsDone;
        // the test's own record of every hold (start, and the first moment it was seen ended), independent of
        // IBCAdmin's compressed history: the replacement's true anchor is the start of the first hold standing at or
        // after its due time
        uint64[64] memory gStart;
        uint64[64] memory gEnd;
        uint256 gn;
        uint64 dipStart; // when the standing hold fell below two guardian flags (its grace runs from then)

        for (uint256 step = 0; step < 60 && !(settingsDone && seatsDone); step++) {
            uint256 r = uint256(keccak256(abi.encode(seed, step)));
            uint256 op = r % 4;
            address key = keys[(r >> 8) % 6];
            if (op < 2) {
                // a replaced watch key is no key any more: its call is refused, which changes nothing
                vm.prank(key);
                (bool done,) = address(admin)
                    .call(op == 0 ? abi.encodeCall(admin.setFlag, ()) : abi.encodeCall(admin.clearFlag, ()));
                done;
            } else if ((r >> 24) % 8 == 0 && _now() < recorded + (6 * TD)) {
                // the boundaries: a flag cleared now starts a dip whose grace ends exactly when the change is due
                vm.warp(recorded + (6 * TD));
            } else {
                uint256[4] memory dts = [uint256((1 * TD / 24)), (12 * TD / 24), (1 * TD), (3 * TD)];
                _skip(dts[(r >> 16) % 4]);
            }

            bool flagged;
            IGuardians.Flag[6] memory f = admin.flags();
            for (uint256 i = 0; i < 6; i++) {
                if (f[i].blockNumber != 0) flagged = true;
            }
            IGuardians.Flag memory h = admin.hold();
            bool holdStands = h.blockNumber != 0;
            // the exact end (exclusive): a dip's grace ends it 24 hours after the dip started (observed at the step
            // that cleared the flag, with no time passing); any other end is the moment it is observed
            if (gn != 0 && gEnd[gn - 1] == 0 && (!holdStands || h.time != gStart[gn - 1])) {
                gEnd[gn - 1] =
                    dipStart != 0 && _now() >= uint256(dipStart) + (1 * TD) ? dipStart + (1 * TD) : uint64(_now());
                dipStart = 0;
            }
            if (holdStands && (gn == 0 || gStart[gn - 1] != h.time)) gStart[gn++] = h.time;
            {
                uint256 gFlags;
                for (uint256 i = 0; i < 4; i++) {
                    if (f[i].blockNumber != 0) gFlags++;
                }
                if (holdStands && gFlags < 2 && dipStart == 0) dipStart = uint64(_now());
                if (gFlags >= 2) dipStart = 0;
            }
            // the earliest qualifying hold by the test's own record (its seen end can only be late, so this anchor
            // can only be early: a safe lower bound)
            uint64 lower;
            for (uint256 k = 0; k < gn && lower == 0; k++) {
                if (gEnd[k] == 0 || gEnd[k] > recorded + (7 * TD)) lower = gStart[k];
            }

            if (!settingsDone) {
                bool should = _now() >= recorded + (7 * TD) && !flagged && !holdStands;
                (bool ok,) = address(admin).call(abi.encodeCall(admin.execute, (settings)));
                assertEq(ok, should, "a 7-day decision runs exactly when matured and unflagged");
                settingsDone = ok;
            }
            if (!seatsDone) {
                uint64 anchor = admin.replacementAnchor(admin.epoch(), seats);
                (bool ok,) = address(admin).call(abi.encodeCall(admin.execute, (seats)));
                ok = ok && admin.decision(admin.epoch(), seats).state == S.EXECUTED;
                uint64 pinned = admin.replacementAnchor(admin.epoch(), seats);
                // never before its 7 days; the anchor, once pinned, never moves
                if (anchor != 0) assertEq(pinned, anchor, "an anchor never moves");
                // the anchor is the start of a hold: one standing at or after the due time (it may have begun before)
                if (pinned != 0) assertLe(pinned, _now(), "anchored at a hold already started");
                bool due = _now() >= recorded + (7 * TD);
                // independently of IBCAdmin's anchor: under a hold, never before the true anchor plus 21 days
                if (ok && holdStands) assertGe(_now(), uint256(lower) + (21 * TD), "never before the true anchor + 21");
                if (pinned != 0) assertGe(pinned, lower, "never anchored before the first qualifying hold");
                // lands exactly when due with no hold standing, or under a hold from its anchor plus 21 days
                bool should = due && (!holdStands || (pinned != 0 && _now() >= uint256(pinned) + (21 * TD)));
                assertEq(ok, should, "a replacement lands exactly when due and unheld, or at its anchor plus (21 * TD)");
                seatsDone = ok;
            }
        }
    }

    /// @notice The anchor at the due-time boundary, against an independent model: a hold from day 1 whose dip starts
    /// around day 6 (two hours either side, the exact point included), so its exclusive end falls just before, at or
    /// just after the due time (day 7); a new hold from day 20. The anchor is day 1 only if the first hold still
    /// stood after the due time, else day 20.
    /// forge-config: default.fuzz.runs = 64
    function testFuzz_anchorAtTheDueBoundary(uint256 x) public {
        uint256 t0 = _now();
        uint64 seq = admin.lastSeq() + 1;
        _recvGov(_env(seq, S.KIND_SEATS, P.seat1(3, makeAddr("fresh"))));
        uint256 due = t0 + (7 * TD);
        uint256 clearAt = t0 + (6 * TD) + (x % 5) * (1 * TD / 24) - (2 * TD / 24);
        vm.warp(t0 + (1 * TD));
        vm.prank(G[0]);
        admin.setFlag();
        vm.prank(G[1]);
        admin.setFlag();
        vm.warp(clearAt);
        vm.prank(G[1]);
        admin.clearFlag();
        vm.warp(t0 + (20 * TD));
        vm.prank(G[1]);
        admin.setFlag();
        vm.warp(t0 + (22 * TD));
        admin.execute(seq);
        uint256 end = clearAt + (1 * TD); // the first hold's exclusive end
        uint256 expected = end > due ? t0 + (1 * TD) : t0 + (20 * TD);
        assertEq(admin.replacementAnchor(admin.epoch(), seq), expected, "the anchor at the due-time boundary");
    }
}

