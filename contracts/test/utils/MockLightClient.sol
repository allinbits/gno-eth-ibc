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

    /// @notice Strict mode: proves only the (path, value) pairs set, and the absence of every other path.
    bool public strict;
    mapping(bytes32 path => bytes32 value) internal members;

    function setStrict(bool s) external {
        strict = s;
    }

    function setMember(bytes[] memory path, bytes memory value) external {
        members[keccak256(abi.encode(path))] = keccak256(value);
    }

    function verifyMembership(ILightClientMsgs.MsgVerifyMembership calldata m) external view returns (uint256) {
        if (strict) {
            bytes32 v = members[keccak256(abi.encode(m.path))];
            require(v != bytes32(0) && v == keccak256(m.value), "membership not proven");
        }
        return timestamp == 0 ? block.timestamp : timestamp;
    }

    function verifyNonMembership(ILightClientMsgs.MsgVerifyNonMembership calldata m) external view returns (uint256) {
        if (strict) require(members[keccak256(abi.encode(m.path))] == bytes32(0), "non-membership not proven");
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
