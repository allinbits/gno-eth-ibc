// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

import { ILightClientMsgs } from "@eureka/msgs/ILightClientMsgs.sol";

import { GnoLightClient } from "../src/GnoLightClient.sol";
import { IGnoLightClientMsgs as Msgs } from "../src/msgs/IGnoLightClientMsgs.sol";

/// @notice updateClient gas against validator set size, on fixtures from fixtures/cmd/genfixtures (gas.json):
/// equal-power sets of 3, 7, 20, 50 and 100 secp256k1 validators. Each measured call starts from cold storage
/// (vm.cool) and from the state its case needs (state snapshots). Prints execution gas and an estimate of the
/// full transaction cost: 21000 + calldata at 16 gas per non-zero and 4 per zero byte of the
/// updateClient(bytes) calldata.
contract GasScalingTest is Test {
    string internal fx;

    uint256 internal constant CASES = 5;

    function setUp() public {
        fx = vm.readFile("test/fixtures/gas.json");
    }

    function _bytes(uint256 i, string memory field) internal view returns (bytes memory) {
        return vm.parseJsonBytes(fx, string.concat(".cases[", vm.toString(i), "].", field));
    }

    function _calldataGas(bytes memory data) internal pure returns (uint256 g) {
        for (uint256 i = 0; i < data.length; ++i) {
            g += data[i] == 0 ? 4 : 16;
        }
    }

    function _measure(GnoLightClient client, uint256 i, string memory field, string memory label) internal {
        bytes memory m = _bytes(i, field);
        bytes memory callData = abi.encodeCall(GnoLightClient.updateClient, (m));
        vm.cool(address(client));
        ILightClientMsgs.UpdateResult res = client.updateClient(m);
        assertEq(uint8(res), uint8(ILightClientMsgs.UpdateResult.Update), label);
        uint256 execGas = vm.lastCallGas().gasTotalUsed;
        uint256 txGas = 21_000 + _calldataGas(callData) + execGas;
        uint256 sigs = abi.decode(m, (Msgs.Header)).commit.signatures.length / 81;
        console.log(
            string.concat(
                vm.toString(vm.parseJsonUint(fx, string.concat(".cases[", vm.toString(i), "].n"))),
                " | ",
                vm.toString(sigs),
                " | ",
                label,
                " | ",
                vm.toString(execGas),
                " | ",
                vm.toString(callData.length),
                " | ",
                vm.toString(txGas)
            )
        );
    }

    function test_gasScaling() public {
        Msgs.ConsensusState memory trusted = abi.decode(_bytes(0, "consensusState"), (Msgs.ConsensusState));
        vm.warp(trusted.timestamp / 1e9 + 120);
        console.log("n | signatures | case | exec gas | calldata bytes | est. tx gas");
        for (uint256 i = 0; i < CASES; ++i) {
            GnoLightClient client = new GnoLightClient(
                abi.decode(_bytes(i, "clientState"), (Msgs.ClientState)),
                abi.decode(_bytes(i, "consensusState"), (Msgs.ConsensusState))
            );
            uint256 fresh = vm.snapshotState();
            _measure(client, i, "uncachedAll", "keys, all sign, set changes next");
            vm.revertToState(fresh);
            _measure(client, i, "uncachedMin", "keys, fewest signers, set changes next");
            vm.revertToState(fresh);
            _measure(client, i, "firstSight", "keys, fewest signers, set gets cached");
            uint256 cached = vm.snapshotState();
            _measure(client, i, "cachedAll", "cached set, all sign");
            vm.revertToState(cached);
            _measure(client, i, "cachedMin", "cached set, fewest signers");
            vm.revertToState(cached);
            _measure(client, i, "nonAdjacentSame", "non-adjacent, cached same set, fewest signers");
            vm.revertToState(cached);
            _measure(client, i, "nonAdjacentRotated", "non-adjacent, 1 validator rotated, trust over cached set");
        }
    }
}
