// SPDX-License-Identifier: LicenseRef-GNO-Network-GPL
pragma solidity ^0.8.28;

// The differential model follows gnolang/bridges (branch ethereum-draft),
// ethereum/bridge/contracts/test/GuardiansModel.t.sol: the library against an independent transcription of its rules.
// Copyright (C) 2026 NewTendermint, LLC. GNO Network General Public License: see contracts/licenses/.

import { Test } from "forge-std/Test.sol";

import { IGuardians } from "../src/interfaces/IGuardians.sol";
import { Guardians } from "../src/lib/Guardians.sol";

/// @notice The library holding one object's guardians, plus a second flag set over the same keys (as each transfer
/// route of GnoICS20Transfer has).
contract GuardiansHarness {
    using Guardians for Guardians.State;

    Guardians.State internal g;
    Guardians.Flags internal other;

    uint64 internal constant GRACE = 1 days;

    function init(address[6] memory k) external {
        g.init(k);
    }

    function setFlag(address key) external returns (uint256) {
        return Guardians.setFlag(g.k, g.f, key, uint64(block.number), uint64(block.timestamp), GRACE);
    }

    function clearFlag(address key) external returns (uint256) {
        return Guardians.clearFlag(g.k, g.f, key, uint64(block.number), uint64(block.timestamp), GRACE);
    }

    function unpause(uint64 before) external returns (uint256) {
        return Guardians.unpause(g.k, g.f, before, uint64(block.number), uint64(block.timestamp), GRACE);
    }

    function replace(IGuardians.SeatKey[] memory pairs) external {
        g.replace(pairs, uint64(block.number), uint64(block.timestamp), GRACE);
    }

    function setOtherFlag(address key) external {
        Guardians.setFlag(g.k, other, key, uint64(block.number), uint64(block.timestamp), GRACE);
    }

    function otherAnyFlag() external view returns (bool) {
        return Guardians.anyFlag(g.k, other);
    }

    function otherHold() external view returns (bool stands) {
        (stands,,) = Guardians.hold(g.k, other, uint64(block.timestamp), GRACE);
    }

    function keys() external view returns (address[6] memory) {
        return g.k.keys;
    }

    function flags() external view returns (IGuardians.Flag[6] memory) {
        return Guardians.flags(g.k, g.f);
    }

    function anyFlag() external view returns (bool) {
        return Guardians.anyFlag(g.k, g.f);
    }

    function hold() external view returns (bool stands, uint64 b, uint64 t) {
        return Guardians.hold(g.k, g.f, uint64(block.timestamp), GRACE);
    }
}

/// @notice An independent transcription of the rules (eager flag clearing, explicit options).
contract GuardiansModel {
    struct Opt {
        bool some;
        uint64 b;
        uint64 t;
    }

    address[6] public keys;
    Opt[6] internal fl;
    Opt internal holdSince;
    Opt internal dipSince;
    uint64 internal constant GRACE = 1 days;

    function init(address[6] memory k) external {
        keys = k;
    }

    function _pos(address key) internal view returns (bool, uint256) {
        for (uint256 i = 0; i < 6; i++) {
            if (key != address(0) && keys[i] == key) return (true, i);
        }
        return (false, 0);
    }

    function _guardianFlags() internal view returns (uint256 n) {
        for (uint256 i = 0; i < 4; i++) {
            if (fl[i].some) n++;
        }
    }

    function _settle() internal {
        if (holdSince.some && dipSince.some && block.timestamp >= dipSince.t && block.timestamp - dipSince.t >= GRACE) {
            delete holdSince;
            delete dipSince;
        }
    }

    function _recompute() internal {
        if (_guardianFlags() >= 2) {
            if (!holdSince.some) holdSince = Opt(true, uint64(block.number), uint64(block.timestamp));
            delete dipSince;
        } else if (holdSince.some && !dipSince.some) {
            dipSince = Opt(true, uint64(block.number), uint64(block.timestamp));
        }
    }

    function hold() public view returns (bool) {
        if (!holdSince.some) return false;
        if (_guardianFlags() >= 2) return true;
        return dipSince.some && (block.timestamp < dipSince.t || block.timestamp - dipSince.t < GRACE);
    }

    function setFlag(address key) external returns (bool ok) {
        (bool found, uint256 i) = _pos(key);
        if (!found) return false;
        _settle();
        fl[i] = Opt(true, uint64(block.number), uint64(block.timestamp));
        _recompute();
        return true;
    }

    function clearFlag(address key) external returns (bool ok) {
        (bool found, uint256 i) = _pos(key);
        if (!found) return false;
        _settle();
        delete fl[i];
        _recompute();
        return true;
    }

    function unpause(uint64 before) external returns (bool ok, uint256 n) {
        _settle();
        if (hold()) return (false, 0);
        for (uint256 i = 0; i < 6; i++) {
            if (fl[i].some && fl[i].b < before) {
                delete fl[i];
                n++;
            }
        }
        _recompute();
        return (true, n);
    }

    function replace(IGuardians.SeatKey[] memory pairs) external returns (bool ok) {
        if (pairs.length == 0 || pairs.length > 4) return false;
        address[6] memory next = keys;
        bool[6] memory seen;
        uint256 g;
        uint256 w;
        for (uint256 p = 0; p < pairs.length; p++) {
            uint256 s = pairs[p].seat;
            if (s >= 6 || seen[s] || pairs[p].key == address(0) || keys[s] == pairs[p].key) return false;
            seen[s] = true;
            next[s] = pairs[p].key;
            if (s < 4) g++;
            else w++;
        }
        if (g > 2 || w > 2) return false;
        for (uint256 i = 0; i < 6; i++) {
            for (uint256 j = 0; j < i; j++) {
                if (next[i] == next[j]) return false;
            }
        }
        _settle();
        bool cleared;
        for (uint256 p = 0; p < pairs.length; p++) {
            uint256 s = pairs[p].seat;
            if (s < 4 && fl[s].some) cleared = true;
            delete fl[s];
            keys[s] = pairs[p].key;
        }
        if (cleared && _guardianFlags() < 2) {
            delete holdSince;
            delete dipSince;
        } else {
            _recompute();
        }
        return true;
    }

    function flagOf(uint256 i) external view returns (Opt memory) {
        return fl[i];
    }

    function anyFlag() external view returns (bool) {
        for (uint256 i = 0; i < 6; i++) {
            if (fl[i].some) return true;
        }
        return false;
    }
}

contract GuardiansTest is Test {
    GuardiansHarness internal h;
    GuardiansModel internal m;
    address[6] internal K;

    function setUp() public {
        for (uint256 i = 0; i < 6; i++) {
            K[i] = address(uint160(0x1000 + i));
        }
        h = new GuardiansHarness();
        m = new GuardiansModel();
        h.init(K);
        m.init(K);
        vm.roll(100);
        vm.warp(1_000_000);
    }

    function _pairs1(uint8 seat, address key) internal pure returns (IGuardians.SeatKey[] memory p) {
        p = new IGuardians.SeatKey[](1);
        p[0] = IGuardians.SeatKey(seat, key);
    }

    function _step(uint256 dt) internal {
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + dt);
    }

    // ------------------------------------------------------------------------------------------ unit rules --

    function test_init_refusesZeroAndDuplicate() public {
        GuardiansHarness x = new GuardiansHarness();
        address[6] memory k = K;
        k[3] = address(0);
        vm.expectRevert(IGuardians.UnknownKey.selector);
        x.init(k);
        k[3] = K[1];
        vm.expectRevert(IGuardians.DuplicateKey.selector);
        x.init(k);
    }

    function test_flag_unknownKeyRefused() public {
        vm.expectRevert(IGuardians.UnknownKey.selector);
        h.setFlag(address(0xBEEF));
        vm.expectRevert(IGuardians.UnknownKey.selector);
        h.clearFlag(address(0));
    }

    function test_oneFlag_pauses_noHold() public {
        h.setFlag(K[4]); // a watch key
        assertTrue(h.anyFlag());
        (bool stands,,) = h.hold();
        assertFalse(stands);
        h.setFlag(K[5]);
        (stands,,) = h.hold();
        assertFalse(stands, "watch flags never make a hold");
    }

    function test_twoGuardianFlags_hold_endsAfterGraceBelowTwo() public {
        h.setFlag(K[0]);
        _step(10);
        h.setFlag(K[2]);
        (bool stands, uint64 b, uint64 t) = h.hold();
        assertTrue(stands);
        assertEq(b, vm.getBlockNumber());
        assertEq(t, vm.getBlockTimestamp());
        _step(100);
        h.clearFlag(K[0]); // dip starts
        (stands,,) = h.hold();
        assertTrue(stands);
        _step(1 days - 1);
        (stands,,) = h.hold();
        assertTrue(stands);
        _step(1);
        (stands,,) = h.hold();
        assertFalse(stands, "a dip of the grace's length ends it");
        assertTrue(h.anyFlag(), "the remaining flag still pauses");
    }

    function test_shortDip_keepsHoldStart() public {
        h.setFlag(K[0]);
        h.setFlag(K[1]);
        (, uint64 b0,) = h.hold();
        _step(60);
        h.clearFlag(K[1]);
        _step(3600);
        h.setFlag(K[3]); // back to two inside the grace
        (bool stands, uint64 b,) = h.hold();
        assertTrue(stands);
        assertEq(b, b0, "the hold keeps its start");
    }

    function test_unpause_refusedUnderHold_clearsOnlyEarlier() public {
        h.setFlag(K[0]);
        h.setFlag(K[1]);
        vm.expectRevert(IGuardians.HoldStands.selector);
        h.unpause(uint64(vm.getBlockNumber() + 1));

        h.clearFlag(K[1]);
        _step(1 days);
        uint64 before = uint64(vm.getBlockNumber());
        h.setFlag(K[4]); // set at `before`: not cleared by an unpause before it
        _step(1);
        assertEq(h.unpause(before), 1);
        IGuardians.Flag[6] memory f = h.flags();
        assertEq(f[0].blockNumber, 0);
        assertEq(f[4].blockNumber, before);
    }

    function test_replace_rules() public {
        IGuardians.SeatKey[] memory p = new IGuardians.SeatKey[](3);
        p[0] = IGuardians.SeatKey(0, address(0xA));
        p[1] = IGuardians.SeatKey(1, address(0xB));
        p[2] = IGuardians.SeatKey(2, address(0xC));
        vm.expectRevert(IGuardians.TooManyGuardians.selector);
        h.replace(p);

        vm.expectRevert(IGuardians.CurrentKey.selector);
        h.replace(_pairs1(2, K[2]));
        vm.expectRevert(IGuardians.DuplicateKey.selector);
        h.replace(_pairs1(2, K[5]));
        vm.expectRevert(IGuardians.BadSeat.selector);
        h.replace(_pairs1(6, address(0xA)));
        vm.expectRevert(IGuardians.UnknownKey.selector);
        h.replace(_pairs1(1, address(0)));
        vm.expectRevert(IGuardians.BadSeat.selector);
        h.replace(new IGuardians.SeatKey[](0));

        IGuardians.SeatKey[] memory twice = new IGuardians.SeatKey[](2);
        twice[0] = IGuardians.SeatKey(4, address(0xA));
        twice[1] = IGuardians.SeatKey(4, address(0xB));
        vm.expectRevert(IGuardians.BadSeat.selector);
        h.replace(twice);

        IGuardians.SeatKey[] memory four = new IGuardians.SeatKey[](4);
        four[0] = IGuardians.SeatKey(0, address(0xA));
        four[1] = IGuardians.SeatKey(3, address(0xB));
        four[2] = IGuardians.SeatKey(4, address(0xC));
        four[3] = IGuardians.SeatKey(5, address(0xD));
        h.replace(four);
        address[6] memory k = h.keys();
        assertEq(k[0], address(0xA));
        assertEq(k[3], address(0xB));
        assertEq(k[5], address(0xD));
    }

    function test_replace_ofHolder_endsHoldAtOnce() public {
        h.setFlag(K[0]);
        h.setFlag(K[1]);
        h.replace(_pairs1(1, address(0xA)));
        (bool stands,,) = h.hold();
        assertFalse(stands);
        assertTrue(h.anyFlag());
    }

    function test_replace_retiresFlagsOnEveryFlagSet() public {
        h.setOtherFlag(K[2]);
        assertTrue(h.otherAnyFlag());
        h.replace(_pairs1(2, address(0xA)));
        assertFalse(h.otherAnyFlag(), "the replaced key's flag no longer stands");
        h.setOtherFlag(address(0xA));
        assertTrue(h.otherAnyFlag());
    }

    function test_otherFlagSet_holdIsItsOwn() public {
        h.setOtherFlag(K[0]);
        h.setOtherFlag(K[1]);
        assertTrue(h.otherHold());
        (bool stands,,) = h.hold();
        assertFalse(stands);
        assertFalse(h.anyFlag());
    }

    // ------------------------------------------------------------------------------- differential fuzzing --

    /// @notice Random sequences of flags, clears, unpauses, replacements and clock steps: the library and the
    /// model agree on every flag, on the hold and on every refusal.
    function testFuzz_matchesModel(uint256 seed) public {
        address[12] memory pool;
        for (uint256 i = 0; i < 6; i++) {
            pool[i] = K[i];
            pool[6 + i] = address(uint160(0x2000 + i));
        }
        for (uint256 step = 0; step < 40; step++) {
            seed = uint256(keccak256(abi.encode(seed, step)));
            uint256 op = seed % 6;
            address key = pool[(seed >> 8) % 12];
            if (op == 0) {
                bool ok = m.setFlag(key);
                if (!ok) vm.expectRevert(IGuardians.UnknownKey.selector);
                h.setFlag(key);
            } else if (op == 1) {
                bool ok = m.clearFlag(key);
                if (!ok) vm.expectRevert(IGuardians.UnknownKey.selector);
                h.clearFlag(key);
            } else if (op == 2) {
                uint64 before = uint64(vm.getBlockNumber() - ((seed >> 16) % 4));
                (bool ok, uint256 n) = m.unpause(before);
                if (!ok) {
                    vm.expectRevert(IGuardians.HoldStands.selector);
                    h.unpause(before);
                } else {
                    assertEq(h.unpause(before), n, "cleared");
                }
            } else if (op == 3) {
                uint256 n = 1 + (seed >> 24) % 3;
                IGuardians.SeatKey[] memory p = new IGuardians.SeatKey[](n);
                for (uint256 j = 0; j < n; j++) {
                    p[j] = IGuardians.SeatKey(uint8((seed >> (32 + 8 * j)) % 6), pool[(seed >> (64 + 8 * j)) % 12]);
                }
                bool ok = m.replace(p);
                if (!ok) {
                    vm.expectRevert();
                    h.replace(p);
                } else {
                    h.replace(p);
                }
            } else {
                uint256[4] memory dts = [uint256(1), 3600, 1 days - 1, 1 days];
                _step(dts[(seed >> 40) % 4]);
            }
            // compare
            IGuardians.Flag[6] memory f = h.flags();
            for (uint256 i = 0; i < 6; i++) {
                GuardiansModel.Opt memory o = m.flagOf(i);
                assertEq(f[i].blockNumber, o.some ? o.b : 0, "flag block");
                assertEq(h.keys()[i], m.keys(i), "keys");
            }
            (bool stands,,) = h.hold();
            assertEq(stands, m.hold(), "hold");
            assertEq(h.anyFlag(), m.anyFlag(), "anyFlag");
        }
    }
}
