// SPDX-License-Identifier: LicenseRef-GNO-Network-GPL
pragma solidity ^0.8.28;

// Ported from gnolang/bridges (branch ethereum-draft), ethereum/bridge/contracts/src/PausableGate.sol
// (`_charge` / `_level`, the mint limit's rolling day). Copyright (C) 2026 NewTendermint, LLC. GNO Network General
// Public License: see contracts/licenses/.
// Changes from the source: uint256 amounts with caps bounded by MAX_CAP (so `elapsed * cap` cannot overflow), a
// partial charge for installments (`chargeUpTo`), and no clock factor.

/// @title A leaky bucket metering a daily budget
/// @notice `used` drains at `cap` per day from its last charge: no midnight reset, at most two caps in any 24 hours
/// (a full drain plus one day of refill), and within `t` of a start at level `level0` at most
/// `cap - level0 + cap * t / 1 day` can be charged (ADR pr6375 §7.2, §7.13).
library LeakyBucket {
    /// @notice The largest cap a bucket takes: keeps `elapsed * cap` (elapsed < 2^64) far from overflowing.
    uint256 internal constant MAX_CAP = type(uint128).max;
    uint256 internal constant DAY = 1 days;

    struct Bucket {
        uint256 used;
        uint64 usedAt;
    }

    /// @notice The bucket's level at `now_`: what was charged, less what drained since (`cap` a day).
    function level(Bucket memory b, uint256 cap, uint64 now_) internal pure returns (uint256) {
        uint256 elapsed = now_ > b.usedAt ? now_ - b.usedAt : 0;
        uint256 drained = elapsed * (cap > MAX_CAP ? MAX_CAP : cap) / DAY;
        return b.used > drained ? b.used - drained : 0;
    }

    /// @notice What can still be charged at `now_`.
    function available(Bucket memory b, uint256 cap, uint64 now_) internal pure returns (uint256) {
        uint256 l = level(b, cap, now_);
        return cap > l ? cap - l : 0;
    }

    /// @notice Charges `amount` if it fits under `cap`; leaves the bucket untouched and returns false otherwise.
    function charge(Bucket storage b, uint256 cap, uint256 amount, uint64 now_) internal returns (bool) {
        uint256 l = level(b, cap, now_);
        if (cap < l || amount > cap - l) return false;
        b.used = l + amount;
        b.usedAt = now_;
        return true;
    }

    /// @notice Charges as much of `amount` as fits under `cap` and returns it (zero leaves the bucket untouched).
    function chargeUpTo(Bucket storage b, uint256 cap, uint256 amount, uint64 now_) internal returns (uint256 got) {
        uint256 l = level(b, cap, now_);
        if (cap <= l) return 0;
        got = amount < cap - l ? amount : cap - l;
        if (got == 0) return 0;
        b.used = l + got;
        b.usedAt = now_;
    }
}
