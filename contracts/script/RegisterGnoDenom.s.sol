// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { stdJson } from "forge-std/StdJson.sol";

import { GnoDenoms } from "./GnoDenoms.sol";

/// @title Deploy the voucher of a gno.land denom for its registration by governance
/// @notice Deploys a GnoVoucher with the denom's metadata and prints the parameters of the decision that registers it
/// (ADR pr6375 §5.4 kind 5: `(string clientId, string baseDenom, address voucher, bytes32 codeHash)`), which `ibcgov`
/// sends to IBCAdmin; the registration lands 7 days after it is recorded. It must land before the denom's first
/// transfer to this chain: until then GnoICS20Transfer refuses the denom (default deny). After DeployGnoIBC's
/// hand-over only IBCAdmin can call `setCustomERC20`; DeployGnoIBC registers ugnot itself.
/// @dev Environment:
///   DEPLOYER_PRIVATE_KEY  any funded key (it only deploys the voucher)
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
        string memory clientId = deployments.readString(".clientId");
        string memory denom = vm.envString("GNO_DENOM");
        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        voucher = GnoDenoms.deploy(
            deployments.readAddress(".ics20Transfer"),
            clientId,
            denom,
            vm.envString("VOUCHER_NAME"),
            vm.envString("VOUCHER_SYMBOL"),
            // forge-lint: disable-next-line(unsafe-typecast)
            uint8(decimals)
        );
        vm.stopBroadcast();
        console.log("voucher:", voucher);
        console.log("kind 5 params (abi.encode(clientId, baseDenom, voucher, codeHash)):");
        console.logBytes(abi.encode(clientId, denom, voucher, voucher.codehash));
    }
}
