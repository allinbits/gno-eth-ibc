// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { CodeVerifier } from "./CodeVerifier.sol";

/// @notice Verifies what runs on chain against a clean build, and every pending code decision before it matures.
///
/// - DEPLOYMENTS_FILE (as DeployGnoIBC writes it) gives only IBCAdmin's address; everything else is read from the
///   chain: the transfer and router proxies' live implementation slots, the escrow and voucher beacons'
///   implementations, IBCAdmin's installed executor, and each delegate graph from there.
/// - The launch's verifier and ugnot voucher (`verifyLaunch`).
/// - CANDIDATES_ONLY=true skips the two above: run it from the candidate release's checkout, and the live checks from
///   the running release's checkout.
/// - PENDING_SEQS, PENDING_HASHES, PENDING_CANDIDATES (comma-separated, the same length; optional): each recorded
///   kind 5, 6, 7 or 9 decision of the current epoch, the hash gno.land's envelope must have, and the voucher,
///   verifier, implementation or executor it must install. Each candidate's whole graph is checked.
/// - VOUCHERS, CLIENTS (comma-separated, optional): further registered vouchers and enrolled or attested verifiers
///   (an emergency recovery proposal's `lightClient` included), each rebuilt from its source.
///
/// Reverts on any mismatch.
contract VerifyCodehashes is CodeVerifier {
    using stdJson for string;

    function run() external {
        string memory json = vm.readFile(vm.envString("DEPLOYMENTS_FILE"));
        address admin = json.readAddress(".ibcAdmin");
        // CANDIDATES_ONLY: a candidate of another release is checked from its own release's checkout, where the live
        // code (of the release that runs) cannot match: only the pending decisions and the listed contracts
        if (!vm.envOr("CANDIDATES_ONLY", false)) {
            require(verifyLive(admin), "live code does not match the build");
            require(verifyLaunch(admin), "the launch verifier or voucher does not match the build");
        }
        (,, address ics20) = _system(admin);
        address[] memory vouchers = vm.envOr("VOUCHERS", ",", new address[](0));
        for (uint256 i = 0; i < vouchers.length; i++) {
            require(verifyVoucher(vouchers[i], ics20), "a voucher fails the build");
        }
        address[] memory clients = vm.envOr("CLIENTS", ",", new address[](0));
        for (uint256 i = 0; i < clients.length; i++) {
            require(verifyLightClient(clients[i]), "a verifier fails the build");
        }
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
