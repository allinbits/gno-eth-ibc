// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ILightClient } from "@eureka/interfaces/ILightClient.sol";
import { ILightClientMsgs } from "@eureka/msgs/ILightClientMsgs.sol";

/// @title The light client a retired client id is migrated to (ADR pr6375 §7.12, E12)
/// @notice The router has no freeze of its own, so a route replacement re-points the old client id at this contract
/// (`migrateClient`): it proves nothing, so no receive, acknowledgement, timeout or update goes through that id again.
contract FrozenLightClient is ILightClient {
    error ClientRetired();

    /// @inheritdoc ILightClient
    function updateClient(bytes calldata) external pure returns (ILightClientMsgs.UpdateResult) {
        revert ClientRetired();
    }

    /// @inheritdoc ILightClient
    function verifyMembership(ILightClientMsgs.MsgVerifyMembership calldata) external pure returns (uint256) {
        revert ClientRetired();
    }

    /// @inheritdoc ILightClient
    function verifyNonMembership(ILightClientMsgs.MsgVerifyNonMembership calldata) external pure returns (uint256) {
        revert ClientRetired();
    }

    /// @inheritdoc ILightClient
    function misbehaviour(bytes calldata) external pure {
        revert ClientRetired();
    }

    /// @inheritdoc ILightClient
    function getClientState() external pure returns (bytes memory) {
        revert ClientRetired();
    }

    /// @notice Reads as frozen to anything asking (IGnoLightClientStatus).
    function isFrozen() external pure returns (bool) {
        return true;
    }
}
