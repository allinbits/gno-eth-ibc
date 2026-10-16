// SPDX-License-Identifier: LicenseRef-GNO-Network-GPL
pragma solidity ^0.8.28;

// Ported from gnolang/bridges (branch ethereum-draft), ethereum/bridge/contracts/src/lib/Guardians.sol.
// Copyright (C) 2026 NewTendermint, LLC. GNO Network General Public License: see contracts/licenses/.
// Changes from the source, for the IBC controls (ADR pr6375 §7.4, E7):
//  - seats are numbered 0-3 (guardians) and 4-5 (watch keys), as the governance wire format (§5.4 kind 3) has them;
//  - the keys and an object's flags are separate (`Flags`), so one key list serves several flag sets (each transfer
//    route of GnoICS20Transfer has its own). A flag records the key that set it and stands only while that key
//    still holds the seat, so replacing a key retires its flags on every flag set without walking them;
//  - custom errors live in IGuardians; the clock is real time (no clock factor).

import { IGuardians } from "../interfaces/IGuardians.sol";

/// @title Guardian seats, flags and holds
/// @notice Four guardian seats and two watch keys, no key in two places; a flag per seat carrying the block it was
/// last set at (fresh on every set), which only an unpause reads; and the object's hold: `holdBlock/holdTime`, the
/// moment its standing guardian flags reached two, kept while they stay at two or more and through a dip below two
/// shorter than the grace (24 hours), ended by a dip of the grace's length, after which the next two flags begin a
/// new one. An unpause clears the flags set before a block and is refused under a hold; a replacement (at most two
/// guardians plus either watch key per decision, never a seat's current key) clears the replaced keys' flags and
/// lands through any hold, ending it at once when its own clear of a standing guardian flag leaves fewer than two.
/// @dev A moment is (block number, block time); block number zero stands for "none".
library Guardians {
    uint256 internal constant SEATS = 4;
    uint256 internal constant WATCH = 2;
    uint256 internal constant KEYS = 6;

    /// @notice One object's flags and hold.
    struct Flags {
        /// Each seat's flag: the block and time it was last set (block zero: no flag), and the key that set it.
        uint64[6] flagBlock;
        uint64[6] flagTime;
        address[6] flagKey;
        /// The object's hold: when its standing guardian flags reached two (block zero: none stands).
        uint64 holdBlock;
        uint64 holdTime;
        /// While a hold stands, when its guardian flags last dipped below two (block zero: at two or more).
        uint64 dipBlock;
        uint64 dipTime;
    }

    /// @notice The keys: seats 0-3 (guardians) then watch keys 4-5, and the block each seat's key was set at. A flag
    /// stands only if the seat's current key set it at or after that block, so a key that is replaced and later put
    /// back never revives its old flags.
    struct Keys {
        address[6] keys;
        uint64[6] since;
    }

    /// @notice The keys and one object's flags.
    struct State {
        Keys k;
        Flags f;
    }

    // ------------------------------------------------------------------------------------------------- keys --

    /// @notice Checks a launch key list: every key non-zero, no key twice.
    function checkKeys(address[6] memory keys) internal pure {
        for (uint256 i = 0; i < KEYS; i++) {
            if (keys[i] == address(0)) revert IGuardians.UnknownKey();
            for (uint256 j = 0; j < i; j++) {
                if (keys[i] == keys[j]) revert IGuardians.DuplicateKey();
            }
        }
    }

    /// @notice The launch lists: every key non-zero, no key twice; no flag, no hold.
    function init(State storage g, address[6] memory keys) internal {
        checkKeys(keys);
        g.k.keys = keys;
        for (uint256 i = 0; i < KEYS; i++) {
            (g.f.flagBlock[i], g.f.flagTime[i], g.f.flagKey[i]) = (0, 0, address(0));
        }
        _endHold(g.f);
    }

    /// @notice Replaces the whole key list (a copy kept by another object): every seat whose key changes starts a
    /// new generation at `nowBlock`, retiring the old key's flags on every flag set over this list.
    function setKeys(Keys storage keys, address[6] memory next, uint64 nowBlock) internal {
        checkKeys(next);
        for (uint256 i = 0; i < KEYS; i++) {
            if (keys.keys[i] != next[i]) {
                keys.keys[i] = next[i];
                keys.since[i] = nowBlock;
            }
        }
    }

    /// @notice The index of a key, or KEYS when it holds no seat.
    function position(Keys storage keys, address key) internal view returns (uint256) {
        if (key == address(0)) return KEYS;
        for (uint256 i = 0; i < KEYS; i++) {
            if (keys.keys[i] == key) return i;
        }
        return KEYS;
    }

    function isGuardian(uint256 i) internal pure returns (bool) {
        return i < SEATS;
    }

    // ------------------------------------------------------------------------------------------------ flags --

    /// @notice Whether seat i's flag stands: set, by the key that holds the seat now.
    function standing(Keys storage keys, Flags storage f, uint256 i) internal view returns (bool) {
        return f.flagBlock[i] != 0 && f.flagKey[i] == keys.keys[i] && f.flagBlock[i] >= keys.since[i];
    }

    function anyFlag(Keys storage keys, Flags storage f) internal view returns (bool) {
        for (uint256 i = 0; i < KEYS; i++) {
            if (standing(keys, f, i)) return true;
        }
        return false;
    }

    function guardianFlags(Keys storage keys, Flags storage f) internal view returns (uint256 n) {
        for (uint256 i = 0; i < SEATS; i++) {
            if (standing(keys, f, i)) n++;
        }
    }

    /// @notice The hold standing at `nowTime`, if any, and its start: a pure function of the stored moments and the
    /// clock, so a dip that has run its course reads as the hold's end before anything is written.
    function hold(
        Keys storage keys,
        Flags storage f,
        uint64 nowTime,
        uint64 grace
    )
        internal
        view
        returns (bool stands, uint64 startBlock, uint64 startTime)
    {
        if (f.holdBlock == 0) return (false, 0, 0);
        if (guardianFlags(keys, f) >= 2) return (true, f.holdBlock, f.holdTime);
        if (f.dipBlock != 0 && (nowTime < f.dipTime || nowTime - f.dipTime < grace)) {
            return (true, f.holdBlock, f.holdTime);
        }
        return (false, 0, 0);
    }

    /// @notice Brings the stored moments up to date before a change: a dip that reached the grace ended the hold,
    /// and so did a hold left with fewer than two standing guardian flags and no dip (its keys were replaced on
    /// another flag set's key list, which retires their flags without touching this set's moments).
    function settle(Keys storage keys, Flags storage f, uint64 nowTime, uint64 grace) internal {
        if (f.holdBlock == 0) return;
        if (f.dipBlock != 0) {
            if (nowTime >= f.dipTime && nowTime - f.dipTime >= grace) _endHold(f);
        } else if (guardianFlags(keys, f) < 2) {
            _endHold(f);
        }
    }

    /// @notice After a change: two standing guardian flags start a hold (or end a dip); fewer start a dip.
    function recompute(Keys storage keys, Flags storage f, uint64 nowBlock, uint64 nowTime) internal {
        if (guardianFlags(keys, f) >= 2) {
            if (f.holdBlock == 0) (f.holdBlock, f.holdTime) = (nowBlock, nowTime);
            (f.dipBlock, f.dipTime) = (0, 0);
        } else if (f.holdBlock != 0 && f.dipBlock == 0) {
            (f.dipBlock, f.dipTime) = (nowBlock, nowTime);
        }
    }

    /// @notice A key sets its own flag at now (fresh on every set). Returns its seat.
    function setFlag(
        Keys storage keys,
        Flags storage f,
        address key,
        uint64 nowBlock,
        uint64 nowTime,
        uint64 grace
    )
        internal
        returns (uint256 i)
    {
        i = position(keys, key);
        if (i == KEYS) revert IGuardians.UnknownKey();
        settle(keys, f, nowTime, grace);
        (f.flagBlock[i], f.flagTime[i], f.flagKey[i]) = (nowBlock, nowTime, key);
        recompute(keys, f, nowBlock, nowTime);
    }

    /// @notice A key clears its own flag. Returns its seat.
    function clearFlag(
        Keys storage keys,
        Flags storage f,
        address key,
        uint64 nowBlock,
        uint64 nowTime,
        uint64 grace
    )
        internal
        returns (uint256 i)
    {
        i = position(keys, key);
        if (i == KEYS) revert IGuardians.UnknownKey();
        settle(keys, f, nowTime, grace);
        (f.flagBlock[i], f.flagTime[i], f.flagKey[i]) = (0, 0, address(0));
        recompute(keys, f, nowBlock, nowTime);
    }

    /// @notice An unpause: clears every flag last set at a block before `beforeBlock`, refused while a hold stands.
    /// Returns how many standing flags it cleared.
    function unpause(
        Keys storage keys,
        Flags storage f,
        uint64 beforeBlock,
        uint64 nowBlock,
        uint64 nowTime,
        uint64 grace
    )
        internal
        returns (uint256)
    {
        settle(keys, f, nowTime, grace);
        (bool stands,,) = hold(keys, f, nowTime, grace);
        if (stands) revert IGuardians.HoldStands();
        return clearBefore(keys, f, beforeBlock, nowBlock, nowTime, grace);
    }

    /// @notice Clears every flag last set at a block before `beforeBlock`, whatever stands (for a flag set whose
    /// holds mean nothing, like a route's refunds flags). Returns how many standing flags it cleared.
    function clearBefore(
        Keys storage keys,
        Flags storage f,
        uint64 beforeBlock,
        uint64 nowBlock,
        uint64 nowTime,
        uint64 grace
    )
        internal
        returns (uint256 n)
    {
        settle(keys, f, nowTime, grace);
        for (uint256 i = 0; i < KEYS; i++) {
            uint64 b = f.flagBlock[i];
            if (b != 0 && b < beforeBlock) {
                if (standing(keys, f, i)) n++;
                (f.flagBlock[i], f.flagTime[i], f.flagKey[i]) = (0, 0, address(0));
            }
        }
        recompute(keys, f, nowBlock, nowTime);
    }

    // ---------------------------------------------------------------------------------------- replacement --

    /// @notice Why a replacement would be refused, or zero: one to four pairs of (seat 0-5, key); no seat twice; no
    /// zero key; never a seat's current key; at most two guardian seats; no key in two places afterwards.
    function checkReplace(Keys storage keys, IGuardians.SeatKey[] memory pairs) internal view returns (bytes4) {
        if (pairs.length == 0 || pairs.length > 4) return IGuardians.BadSeat.selector;
        address[6] memory next = keys.keys;
        bool[6] memory replaced;
        uint256 guardians;
        uint256 watch;
        for (uint256 p = 0; p < pairs.length; p++) {
            uint256 i = pairs[p].seat;
            address key = pairs[p].key;
            if (i >= KEYS || replaced[i]) return IGuardians.BadSeat.selector;
            if (key == address(0)) return IGuardians.UnknownKey.selector;
            if (keys.keys[i] == key) return IGuardians.CurrentKey.selector;
            if (isGuardian(i)) guardians++;
            else watch++;
            next[i] = key;
            replaced[i] = true;
        }
        if (guardians > 2) return IGuardians.TooManyGuardians.selector;
        if (watch > WATCH) return IGuardians.TooManyWatch.selector;
        for (uint256 i = 0; i < KEYS; i++) {
            for (uint256 j = 0; j < i; j++) {
                if (next[i] == next[j]) return IGuardians.DuplicateKey.selector;
            }
        }
        return bytes4(0);
    }

    /// @notice A replacement of seats: refused as `checkReplace` says; the replaced keys' flags cleared; a hold ended
    /// at once when this clear of a standing guardian flag leaves fewer than two.
    function replace(
        State storage g,
        IGuardians.SeatKey[] memory pairs,
        uint64 nowBlock,
        uint64 nowTime,
        uint64 grace
    )
        internal
    {
        bytes4 err = checkReplace(g.k, pairs);
        if (err != bytes4(0)) {
            assembly ("memory-safe") {
                mstore(0, err)
                revert(0, 4)
            }
        }
        Flags storage f = g.f;
        settle(g.k, f, nowTime, grace);
        bool clearedGuardian;
        for (uint256 p = 0; p < pairs.length; p++) {
            uint256 i = pairs[p].seat;
            if (isGuardian(i) && standing(g.k, f, i)) clearedGuardian = true;
            (f.flagBlock[i], f.flagTime[i], f.flagKey[i]) = (0, 0, address(0));
            g.k.keys[i] = pairs[p].key;
            g.k.since[i] = nowBlock;
        }
        // the 24-hour grace is for a holder's own clearing, never for GovDAO's replacement of the holders; a
        // replacement of nobody holding (a watch key, a seat whose flag is down) during a dip ends nothing
        if (clearedGuardian && guardianFlags(g.k, f) < 2) _endHold(f);
        else recompute(g.k, f, nowBlock, nowTime);
    }

    /// @notice No hold stands, and no dip.
    function _endHold(Flags storage f) private {
        f.holdBlock = 0;
        f.holdTime = 0;
        f.dipBlock = 0;
        f.dipTime = 0;
    }

    // ------------------------------------------------------------------------------------------------ views --

    /// @notice The standing flags (a flag whose key no longer holds the seat reads as none).
    function flags(Keys storage keys, Flags storage f) internal view returns (IGuardians.Flag[6] memory out) {
        for (uint256 i = 0; i < KEYS; i++) {
            if (standing(keys, f, i)) out[i] = IGuardians.Flag(f.flagBlock[i], f.flagTime[i]);
        }
    }

    /// @notice The standing hold's start at `nowTime`, zero when none stands.
    function holdView(
        Keys storage keys,
        Flags storage f,
        uint64 nowTime,
        uint64 grace
    )
        internal
        view
        returns (IGuardians.Flag memory)
    {
        (bool stands, uint64 b, uint64 t) = hold(keys, f, nowTime, grace);
        if (!stands) return IGuardians.Flag(0, 0);
        return IGuardians.Flag(b, t);
    }
}
