// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ILightClient } from "@eureka/interfaces/ILightClient.sol";
import { ILightClientMsgs } from "@eureka/msgs/ILightClientMsgs.sol";

import { IGnoLightClientMsgs } from "../../src/msgs/IGnoLightClientMsgs.sol";

/// @notice A light client that proves whatever it is asked (tests drive the router without real proofs), with the
/// quarantine and status views of GnoLightClient under the test's control.
contract MockLightClient is ILightClient {
    uint256 public timestamp;
    uint64 public transitionTime;
    bool public frozen;
    bool public expired;

    function setTimestamp(uint256 t) external {
        timestamp = t;
    }

    uint64 public transitionCount;

    /// @notice A live transition accepted at time `t` (each call is a new transition).
    function setTransitionTime(uint64 t) external {
        transitionTime = t;
        ++transitionCount;
    }

    function lastTransition() external view returns (uint64 id, uint64 time) {
        return (transitionCount, transitionTime);
    }

    function setStatus(bool frozen_, bool expired_) external {
        (frozen, expired) = (frozen_, expired_);
    }

    function updateClient(bytes calldata) external pure returns (ILightClientMsgs.UpdateResult) {
        return ILightClientMsgs.UpdateResult.Update;
    }

    function verifyMembership(ILightClientMsgs.MsgVerifyMembership calldata) external view returns (uint256) {
        return timestamp == 0 ? block.timestamp : timestamp;
    }

    function verifyNonMembership(ILightClientMsgs.MsgVerifyNonMembership calldata) external view returns (uint256) {
        return timestamp == 0 ? block.timestamp : timestamp;
    }

    function misbehaviour(bytes calldata) external { }

    string public chainId = "gno-test";

    function setChainId(string memory id) external {
        chainId = id;
    }

    /// @notice A GnoLightClient-shaped client state (chain id, frozen).
    function getClientState() external view returns (bytes memory) {
        IGnoLightClientMsgs.ClientState memory cs;
        cs.chainId = chainId;
        cs.isFrozen = frozen;
        return abi.encode(cs);
    }

    function quarantineEnd(uint256 duration) external view returns (uint256) {
        return transitionTime == 0 || duration == 0 ? 0 : uint256(transitionTime) + duration;
    }

    function lastTransitionTime() external view returns (uint64) {
        return transitionTime;
    }

    function isFrozen() external view returns (bool) {
        return frozen;
    }

    function isExpired() external view returns (bool) {
        return expired;
    }
}
