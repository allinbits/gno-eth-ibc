// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";

import { GnoLightClient } from "../../src/GnoLightClient.sol";
import { IGnoLightClientMsgs as Msgs } from "../../src/msgs/IGnoLightClientMsgs.sol";

/// @notice Loads test/fixtures/gno.json, produced from real tm2 code by fixtures/cmd/genfixtures.
abstract contract Fixtures is Test {
    string internal fx;
    uint256 internal t0Seconds; // time of the trusted header at height 10

    function _loadFixtures() internal {
        fx = vm.readFile("test/fixtures/gno.json");
        t0Seconds = vm.parseJsonUint(fx, ".initial.timestampNanos") / 1e9;
    }

    function _initialClientState() internal view returns (Msgs.ClientState memory) {
        return abi.decode(vm.parseJsonBytes(fx, ".initial.clientState"), (Msgs.ClientState));
    }

    function _initialConsensusState() internal view returns (Msgs.ConsensusState memory) {
        return abi.decode(vm.parseJsonBytes(fx, ".initial.consensusState"), (Msgs.ConsensusState));
    }

    function _deploy() internal returns (GnoLightClient) {
        return new GnoLightClient(_initialClientState(), _initialConsensusState());
    }

    function _msg(string memory name) internal view returns (bytes memory) {
        return vm.parseJsonBytes(fx, string.concat(".updates.", name, ".msg"));
    }

    function _header(string memory name) internal view returns (Msgs.Header memory) {
        return abi.decode(_msg(name), (Msgs.Header));
    }

    function _updateUint(string memory name, string memory field) internal view returns (uint256) {
        return vm.parseJsonUint(fx, string.concat(".updates.", name, ".", field));
    }

    function _updateBytes32(string memory name, string memory field) internal view returns (bytes32) {
        return vm.parseJsonBytes32(fx, string.concat(".updates.", name, ".", field));
    }

    function _proofCase(
        string memory kind,
        uint256 i
    )
        internal
        view
        returns (bytes memory key, bytes memory value, bytes memory proof)
    {
        string memory base = string.concat(".proofs.", kind, "[", vm.toString(i), "]");
        key = vm.parseJsonBytes(fx, string.concat(base, ".key"));
        value = vm.parseJsonBytes(fx, string.concat(base, ".value"));
        proof = vm.parseJsonBytes(fx, string.concat(base, ".proof"));
    }
}
