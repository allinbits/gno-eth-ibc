// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { stdJson } from "forge-std/StdJson.sol";

import { GnoDenoms } from "./GnoDenoms.sol";

/// @title Register the voucher of a gno.land denom
/// @notice Deploys a GnoVoucher with the denom's metadata and registers it with ICS20Transfer. It must run before
/// the denom's first transfer to this chain: after that, ICS20Transfer has deployed an 18-decimal IBCERC20.
/// DeployGnoIBC.s.sol registers ugnot itself.
/// @dev Environment:
///   DEPLOYER_PRIVATE_KEY  a key with ERC20_CUSTOMIZER_ROLE (the deployer of DeployGnoIBC has it)
///   DEPLOYMENTS_FILE      the JSON DeployGnoIBC wrote; default deployments/<chainid>.json
///   GNO_DENOM             the denom on gno.land
///   VOUCHER_NAME, VOUCHER_SYMBOL, VOUCHER_DECIMALS  its metadata, with the decimals it has on gno.land
/// Run: forge script script/RegisterGnoDenom.s.sol --rpc-url $ETH_RPC_URL --broadcast
contract RegisterGnoDenom is Script {
    using stdJson for string;

    function run() external returns (address voucher) {
        string memory deployments = vm.readFile(
            vm.envOr("DEPLOYMENTS_FILE", string.concat("deployments/", vm.toString(block.chainid), ".json"))
        );
        uint256 decimals = vm.envUint("VOUCHER_DECIMALS");
        require(decimals <= type(uint8).max, "VOUCHER_DECIMALS out of range");
        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        voucher = GnoDenoms.register(
            deployments.readAddress(".ics20Transfer"),
            deployments.readString(".clientId"),
            vm.envString("GNO_DENOM"),
            vm.envString("VOUCHER_NAME"),
            vm.envString("VOUCHER_SYMBOL"),
            // forge-lint: disable-next-line(unsafe-typecast)
            uint8(decimals)
        );
        vm.stopBroadcast();
    }
}
