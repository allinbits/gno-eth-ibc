// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IGuardians } from "../../src/interfaces/IGuardians.sol";
import { IBCAdminStorage as S } from "../../src/admin/IBCAdminStorage.sol";
import { GovParams as P } from "../utils/GovParams.sol";
import { ControlsFixture } from "./ControlsFixture.sol";

/// @notice The hold state machine as it gates execution (§6.6, §6.7, §7.4): random flags, clears and clock steps by
/// the six keys, with a 7-day decision and a guardian replacement waiting. A 7-day decision executes exactly when it
/// has matured and no flag or hold stands; the replacement never before its 7 days, and under a hold never before
/// its anchor plus 21 days: the first moment a hold stood once it was due, pinned and never reset by later holds.
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
                uint64 anchor = admin.replacementAnchor(admin.epoch(), seats);
                (bool ok,) = address(admin).call(abi.encodeCall(admin.execute, (seats)));
                ok = ok && admin.decision(admin.epoch(), seats).state == S.EXECUTED;
                uint64 pinned = admin.replacementAnchor(admin.epoch(), seats);
                // never before its 7 days; the anchor, once pinned, never moves and is never before the due time
                if (anchor != 0) assertEq(pinned, anchor, "an anchor never moves");
                if (pinned != 0) assertGe(pinned, recorded + 7 days, "never anchored before it was due");
                bool due = _now() >= recorded + 7 days;
                // lands exactly when due with no hold standing, or under a hold from its anchor plus 21 days
                bool should = due && (!holdStands || (pinned != 0 && _now() >= uint256(pinned) + 21 days));
                assertEq(ok, should, "a replacement lands exactly when due and unheld, or at its anchor plus 21 days");
                seatsDone = ok;
            }
        }
    }
}
