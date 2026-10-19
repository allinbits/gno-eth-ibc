// SPDX-License-Identifier: LicenseRef-GNO-Network-GPL
pragma solidity ^0.8.28;

// Ported from gnolang/bridges (branch ethereum-draft),
// ethereum/bridge/contracts/src/interfaces/IPausableGate.sol (its SeatKey and Flag types).
// Copyright (C) 2026 NewTendermint, LLC. GNO Network General Public License: see contracts/licenses/.

/// @title Guardian seats and flags: shared types
/// @notice Seats 0-3 are the guardians, 4-5 the watch keys (ADR pr6375 §5.4 kind 3, §7.4).
interface IGuardians {
    /// @notice One seat to replace: 0-3 a guardian seat, 4-5 a watch key.
    struct SeatKey {
        uint8 seat;
        address key;
    }

    /// @notice A flag or a hold moment: the block and time it was set (block zero: none).
    struct Flag {
        uint64 blockNumber;
        uint64 time;
    }

    /// @notice A hold that ended: when its guardian flags reached two, and when it ended (seconds).
    struct Hold {
        uint64 start;
        uint64 end;
        /// Two or more holds merged when the history overflowed: the interval may span gaps no hold covered.
        bool merged;
    }

    error UnknownKey();
    error DuplicateKey();
    error BadSeat();
    error TooManyGuardians();
    error TooManyWatch();
    error CurrentKey();
    error HoldStands();
}
