// SPDX-License-Identifier: LicenseRef-GNO-Network-GPL
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";

import { LeakyBucket } from "../src/lib/LeakyBucket.sol";

contract BucketHarness {
    using LeakyBucket for LeakyBucket.Bucket;

    LeakyBucket.Bucket internal b;

    function charge(uint256 cap, uint256 amount) external returns (bool) {
        return b.charge(cap, amount, uint64(block.timestamp));
    }

    function chargeUpTo(uint256 cap, uint256 amount) external returns (uint256) {
        return b.chargeUpTo(cap, amount, uint64(block.timestamp));
    }

    function level(uint256 cap) external view returns (uint256) {
        return LeakyBucket.level(b, cap, uint64(block.timestamp));
    }

    function available(uint256 cap) external view returns (uint256) {
        return LeakyBucket.available(b, cap, uint64(block.timestamp));
    }
}

/// @notice E5 / §7.2, §7.13: the leaky bucket behind the receive limits and the refund meter.
contract LeakyBucketTest is Test {
    BucketHarness internal h;

    function setUp() public {
        h = new BucketHarness();
        vm.warp(1_000_000);
    }

    function test_chargeWithinCap_thenRefusedOverCap() public {
        assertTrue(h.charge(100, 60));
        assertFalse(h.charge(100, 41));
        assertEq(h.level(100), 60);
        assertTrue(h.charge(100, 40));
        assertEq(h.available(100), 0);
    }

    function test_drainsAtCapPerDay() public {
        assertTrue(h.charge(86_400, 86_400));
        vm.warp(vm.getBlockTimestamp() + 3600);
        assertEq(h.level(86_400), 86_400 - 3600);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        assertEq(h.level(86_400), 0);
    }

    function test_zeroCap_refusesEverything() public {
        assertFalse(h.charge(0, 1));
        assertEq(h.chargeUpTo(0, 1), 0);
        assertTrue(h.charge(0, 0));
    }

    function test_chargeUpTo_partial() public {
        assertEq(h.chargeUpTo(100, 70), 70);
        assertEq(h.chargeUpTo(100, 70), 30);
        assertEq(h.chargeUpTo(100, 70), 0);
    }

    function test_hugeAmountsDoNotOverflow() public {
        assertFalse(h.charge(LeakyBucket.MAX_CAP, type(uint256).max));
        assertTrue(h.charge(LeakyBucket.MAX_CAP, LeakyBucket.MAX_CAP));
        vm.warp(vm.getBlockTimestamp() + 365 days * 100);
        assertEq(h.level(LeakyBucket.MAX_CAP), 0);
    }

    /// @notice Never above the cap at the moment of a charge; over any 24 hours at most two caps.
    function testFuzz_boundOverOneDay(uint128 cap, uint256 seed) public {
        cap = uint128(bound(cap, 1, type(uint128).max));
        uint256 start = vm.getBlockTimestamp();
        uint256 total;
        for (uint256 i = 0; i < 30; i++) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            vm.warp(vm.getBlockTimestamp() + (seed % (1 days / 10)));
            if (vm.getBlockTimestamp() >= start + 1 days) break;
            uint256 amount = (seed >> 64) % (uint256(cap) + 1);
            if ((seed >> 200) % 2 == 0) {
                if (h.charge(cap, amount)) total += amount;
            } else {
                total += h.chargeUpTo(cap, amount);
            }
            assertLe(h.level(cap), cap, "level above cap");
        }
        assertLe(total, 2 * uint256(cap), "more than two caps in 24 hours");
    }

    /// @notice Within t of a start at level 0, at most cap + cap*t/day is charged.
    function testFuzz_boundOverTime(uint64 cap, uint256 seed) public {
        cap = uint64(bound(cap, 1, type(uint64).max));
        uint256 start = vm.getBlockTimestamp();
        uint256 total;
        for (uint256 i = 0; i < 20; i++) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            vm.warp(vm.getBlockTimestamp() + (seed % 3 days));
            total += h.chargeUpTo(cap, (seed >> 64) % (2 * uint256(cap) + 1));
            uint256 t = vm.getBlockTimestamp() - start;
            assertLe(total, uint256(cap) + uint256(cap) * t / 1 days + 1, "bound");
        }
    }
}
