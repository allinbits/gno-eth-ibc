// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

import { ILightClientMsgs } from "@eureka/msgs/ILightClientMsgs.sol";

import { GnoLightClient } from "../src/GnoLightClient.sol";
import { IGnoLightClientMsgs as Msgs } from "../src/msgs/IGnoLightClientMsgs.sol";

/// @notice updateClient gas against validator set size, on fixtures from fixtures/cmd/genfixtures (gas.json):
/// equal-power sets of 3, 7, 20, 50 and 100 secp256k1 validators. Each case runs on a freshly deployed client
/// (cold storage). Prints execution gas and an estimate of the full transaction cost: 21000 + calldata at
/// 16 gas per non-zero and 4 per zero byte of the updateClient(bytes) calldata.
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

    function _run(uint256 i, string memory field) internal returns (uint256 execGas, uint256 txGas, uint256 size) {
        GnoLightClient client = new GnoLightClient(
            abi.decode(_bytes(i, "clientState"), (Msgs.ClientState)),
            abi.decode(_bytes(i, "consensusState"), (Msgs.ConsensusState))
        );
        bytes memory m = _bytes(i, field);
        bytes memory callData = abi.encodeCall(GnoLightClient.updateClient, (m));
        ILightClientMsgs.UpdateResult res = client.updateClient(m);
        assertEq(uint8(res), uint8(ILightClientMsgs.UpdateResult.Update));
        execGas = vm.lastCallGas().gasTotalUsed;
        txGas = 21_000 + _calldataGas(callData) + execGas;
        size = callData.length;
    }

    function test_gasScaling() public {
        Msgs.ConsensusState memory trusted = abi.decode(_bytes(0, "consensusState"), (Msgs.ConsensusState));
        vm.warp(trusted.timestamp / 1e9 + 120);
        string[4] memory fields = ["adjacentAll", "adjacentMin", "nonAdjacentTrusted", "nonAdjacentSameSet"];
        console.log("n | signers | case | exec gas | calldata bytes | est. tx gas");
        for (uint256 i = 0; i < CASES; ++i) {
            uint256 n = vm.parseJsonUint(fx, string.concat(".cases[", vm.toString(i), "].n"));
            uint256 minSigners = vm.parseJsonUint(fx, string.concat(".cases[", vm.toString(i), "].minSigners"));
            for (uint256 f = 0; f < fields.length; ++f) {
                (uint256 execGas, uint256 txGas, uint256 size) = _run(i, fields[f]);
                console.log(
                    string.concat(
                        vm.toString(n),
                        " | ",
                        vm.toString(f == 1 ? minSigners : n),
                        " | ",
                        fields[f],
                        " | ",
                        vm.toString(execGas),
                        " | ",
                        vm.toString(size),
                        " | ",
                        vm.toString(txGas)
                    )
                );
            }
        }
    }
}
