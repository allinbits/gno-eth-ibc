// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title What the transfer app and IBCAdmin read from a GnoLightClient besides ILightClient
interface IGnoLightClientStatus {
    /// @notice When a `duration`-second quarantine after the latest live validator-set transition ends (0: none).
    function quarantineEnd(uint256 duration) external view returns (uint256);
    /// @notice The latest accepted live transition: its number (0: none) and block time.
    function lastTransition() external view returns (uint64 id, uint64 time);
    function isFrozen() external view returns (bool);
    function isExpired() external view returns (bool);
}
