// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { CodeVerifier } from "./CodeVerifier.sol";

/// @notice Verifies what runs on chain against a clean build, and every pending code decision before it matures.
///
/// - DEPLOYMENTS_FILE (as DeployGnoIBC writes it) gives only IBCAdmin's address; everything else is read from the
///   chain: the transfer and router proxies' live implementation slots, the escrow and voucher beacons'
///   implementations, IBCAdmin's installed executor, and each delegate graph from there.
/// - PENDING_SEQS, PENDING_HASHES, PENDING_CANDIDATES (comma-separated, the same length; optional): each recorded
///   kind 7 or kind 9 decision of the current epoch, the hash gno.land's envelope must have, and the implementation or
///   executor it must install. Each candidate's whole graph is checked.
///
/// Reverts on any mismatch.
contract VerifyCodehashes is CodeVerifier {
    using stdJson for string;

    function run() external view {
        string memory json = vm.readFile(vm.envString("DEPLOYMENTS_FILE"));
        address admin = json.readAddress(".ibcAdmin");
        require(verifyLive(admin), "live code does not match the build");
        uint256[] memory seqs = vm.envOr("PENDING_SEQS", ",", new uint256[](0));
        bytes32[] memory hashes = vm.envOr("PENDING_HASHES", ",", new bytes32[](0));
        address[] memory candidates = vm.envOr("PENDING_CANDIDATES", ",", new address[](0));
        require(seqs.length == hashes.length && seqs.length == candidates.length, "pending lists differ in length");
        for (uint256 i = 0; i < seqs.length; i++) {
            require(
                verifyPending(admin, uint64(seqs[i]), hashes[i], candidates[i]), "a pending candidate fails the build"
            );
        }
    }
}
