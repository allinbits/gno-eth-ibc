// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IGuardians } from "../../src/interfaces/IGuardians.sol";
import { IBCAdminStorage as S } from "../../src/admin/IBCAdminStorage.sol";
import { GovParams as P } from "../utils/GovParams.sol";
import { ControlsFixture } from "./ControlsFixture.sol";

/// @notice The hold state machine as it gates execution (§6.6, §6.7, §7.4): random flags, clears and clock steps by
/// the six keys, with a 7-day decision and a guardian replacement waiting. A 7-day decision executes exactly when it
/// has matured and no flag or hold stands; the replacement never before its 7 days, and under a hold never before
/// day 21 of the earliest hold overlapping its pending life.
contract IBCAdminHoldFuzzTest is ControlsFixture {
    /// forge-config: default.fuzz.runs = 128
    function testFuzz_holdStateMachine(uint256 seed) public {
        uint64 settings = admin.lastSeq() + 1;
        _recvGov(_env(settings, S.KIND_SETTINGS, P.settings(clientId, 1 days)));
        uint64 seats = settings + 1;
        _recvGov(_env(seats, S.KIND_SEATS, P.seat1(5, makeAddr("fresh watch"))));
        uint64 recorded = admin.decision(1, settings).recordedTime;
        address[6] memory keys = [G[0], G[1], G[2], G[3], W[0], W[1]];
        bool settingsDone;
        bool seatsDone;

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
            } else {
                uint256[4] memory dts = [uint256(1 hours), 12 hours, 1 days, 3 days];
                _skip(dts[(r >> 16) % 4]);
            }

            bool flagged;
            IGuardians.Flag[6] memory f = admin.flags();
            for (uint256 i = 0; i < 6; i++) {
                if (f[i].blockNumber != 0) flagged = true;
            }
            IGuardians.Flag memory h = admin.hold();
            bool holdStands = h.blockNumber != 0;

            if (!settingsDone) {
                bool should = _now() >= recorded + 7 days && !flagged && !holdStands;
                (bool ok,) = address(admin).call(abi.encodeCall(admin.execute, (settings)));
                assertEq(ok, should, "a 7-day decision runs exactly when matured and unflagged");
                settingsDone = ok;
            }
            if (!seatsDone) {
                (bool ok,) = address(admin).call(abi.encodeCall(admin.execute, (seats)));
                if (ok) {
                    assertGe(_now(), recorded + 7 days, "never before 7 days");
                    if (holdStands) {
                        uint64 earliest = h.time;
                        IGuardians.Hold[] memory past = admin.holds();
                        for (uint256 i = 0; i < past.length; i++) {
                            if (past[i].end >= recorded && past[i].start < earliest) earliest = past[i].start;
                        }
                        assertGe(_now(), uint256(earliest) + 21 days, "under a hold, never before day 21");
                    }
                } else if (_now() >= recorded + 7 days && !holdStands) {
                    revert("a matured replacement without a hold must land, flags or not");
                }
                seatsDone = ok;
            }
        }
    }
}
