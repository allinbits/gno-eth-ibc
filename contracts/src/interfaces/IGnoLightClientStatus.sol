// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title What the transfer app and IBCAdmin read from a GnoLightClient besides ILightClient
interface IGnoLightClientStatus {
    /// @notice When a `duration`-second quarantine after the latest live validator-set transition ends (0: none).
    function quarantineEnd(uint256 duration) external view returns (uint256);
    /// @notice Block time of the latest accepted live transition (0: none).
    function lastTransitionTime() external view returns (uint64);
    function isFrozen() external view returns (bool);
    function isExpired() external view returns (bool);
}
