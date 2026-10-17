// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { CodeVerifier } from "./CodeVerifier.sol";

/// @notice Verifies a deployment (DEPLOYMENTS_FILE, as DeployGnoIBC writes it) against a clean build: the transfer
/// app's implementation and its controls, reconciliation and evidence modules, IBCAdmin, its executor and the
/// executor's modules. Reverts on any mismatch.
contract VerifyCodehashes is CodeVerifier {
    using stdJson for string;

    function run() external view {
        string memory json = vm.readFile(vm.envString("DEPLOYMENTS_FILE"));
        address impl = json.readAddress(".ics20Implementation");
        address admin = json.readAddress(".ibcAdmin");
        require(verifyGraph(impl, admin), "deployed code does not match the build");
    }
}
