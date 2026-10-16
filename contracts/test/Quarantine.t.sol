// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ILightClientMsgs } from "@eureka/msgs/ILightClientMsgs.sol";

import { GnoLightClient } from "../src/GnoLightClient.sol";
import { Fixtures } from "./utils/Fixtures.sol";

/// @notice E9 / ADR §7.10: the live-epoch quarantine. Fixture sets: A (3 validators) signs heights 10-12, h12
/// announces B (4 validators), B signs h13 and h20; h20From11 skips from 11 straight to a B-signed header.
contract QuarantineTest is Fixtures {
    GnoLightClient internal client;
    uint256 internal constant WEEK = 7 days;

    bytes32 internal setA;
    bytes32 internal setB;

    function setUp() public {
        _loadFixtures();
        client = _deploy();
        vm.warp(t0Seconds + 120);
        setA = _updateBytes32("h11", "nextValidatorsHash");
        setB = _updateBytes32("h12", "nextValidatorsHash");
    }

    function _update(string memory name) internal returns (ILightClientMsgs.UpdateResult) {
        return client.updateClient(_msg(name));
    }

    function test_initial_noQuarantine_liveNextFromTrustedState() public view {
        (bytes32 vals, bytes32 next) = client.liveEpoch();
        assertEq(vals, bytes32(0));
        assertEq(next, setA);
        assertEq(client.lastTransitionTime(), 0);
        assertEq(client.quarantineEnd(WEEK), 0);
        assertFalse(client.isQuarantined(WEEK));
    }

    function test_sameEpochUpdate_isNotATransition() public {
        _update("h11");
        assertEq(client.lastTransitionTime(), 0);
        (bytes32 vals, bytes32 next) = client.liveEpoch();
        assertEq(vals, setA);
        assertEq(next, setA);
    }

    function test_announcedNextSet_startsQuarantine() public {
        _update("h11");
        uint256 t = vm.getBlockTimestamp();
        vm.expectEmit(true, false, false, true, address(client));
        emit GnoLightClient.LiveTransition(12, setA, setB, uint64(t));
        _update("h12");
        assertEq(client.lastTransitionTime(), t);
        assertEq(client.quarantineEnd(WEEK), t + WEEK);
        assertTrue(client.isQuarantined(WEEK));
        vm.warp(t + WEEK - 1);
        assertTrue(client.isQuarantined(WEEK));
        vm.warp(t + WEEK);
        assertFalse(client.isQuarantined(WEEK));
    }

    function test_establishedEpoch_doesNotExtend() public {
        _update("h11");
        _update("h12");
        uint256 t = vm.getBlockTimestamp();
        vm.warp(t + 1 days);
        _update("h13"); // signed by B, the announced next set: the same epoch
        assertEq(client.lastTransitionTime(), t);
        vm.warp(t + 2 days);
        _update("h20From13");
        assertEq(client.lastTransitionTime(), t);
        assertEq(client.quarantineEnd(WEEK), t + WEEK);
    }

    function test_unannouncedSigningSet_startsQuarantine() public {
        _update("h11");
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        _update("h20From11"); // B signs although A announced A: the > 1/3 skip
        assertEq(client.lastTransitionTime(), vm.getBlockTimestamp());
        (bytes32 vals, bytes32 next) = client.liveEpoch();
        assertEq(vals, setB);
        assertEq(next, setB);
    }

    function test_olderAnchor_cannotRestart() public {
        _update("h11");
        _update("h12");
        _update("h13");
        uint256 t = client.lastTransitionTime();
        vm.warp(t + WEEK + 1);
        // anchored at 11 (set A trusted), but the header's sets are the live epoch's: no transition
        _update("h20From11");
        assertEq(client.lastTransitionTime(), t);
        assertFalse(client.isQuarantined(WEEK));
    }

    function test_noOpRepeat_doesNotRestart() public {
        _update("h11");
        _update("h12");
        uint256 t = client.lastTransitionTime();
        vm.warp(t + 1 days);
        assertEq(uint8(_update("h12")), uint8(ILightClientMsgs.UpdateResult.NoOp));
        assertEq(client.lastTransitionTime(), t);
    }

    function test_zeroDuration_disables() public {
        _update("h11");
        _update("h12");
        assertEq(client.quarantineEnd(0), 0);
        assertFalse(client.isQuarantined(0));
    }

    function test_status_frozenAndExpired() public {
        assertFalse(client.isFrozen());
        assertFalse(client.isExpired());
        vm.warp(t0Seconds + vm.parseJsonUint(fx, ".trustingPeriod"));
        assertFalse(client.isExpired()); // the trusted header's sub-second part
        vm.warp(t0Seconds + vm.parseJsonUint(fx, ".trustingPeriod") + 1);
        assertTrue(client.isExpired());
    }

    function test_transitionsAreNumbered() public {
        (uint64 id,) = client.lastTransition();
        assertEq(id, 0);
        _update("h11");
        _update("h12");
        (uint64 id2, uint64 t) = client.lastTransition();
        assertEq(id2, 1);
        assertEq(t, client.lastTransitionTime());
    }

    function testFuzz_quarantineEnd_isTransitionPlusDuration(uint32 duration, uint32 later) public {
        _update("h11");
        _update("h12");
        uint256 t = client.lastTransitionTime();
        vm.warp(t + later);
        assertEq(client.quarantineEnd(duration), duration == 0 ? 0 : t + duration);
        assertEq(client.isQuarantined(duration), duration != 0 && later < duration);
    }
}
