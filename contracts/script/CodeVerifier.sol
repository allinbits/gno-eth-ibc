// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

/// @notice Checks deployed runtime code against a reproducible build of the named source (ADR §6.12, the T5 watch
/// tool): the deployed code must equal the built `deployedBytecode`, every byte outside the immutables the compiler
/// lists. The immutables are then followed: a delegate module's address recorded in one contract is checked in turn
/// against its own build, so a module that is a proxy (whose code is a proxy's, whatever it delegates to) never
/// passes. On-chain pinning fixes code hashes; only this check ties a hash to the source.
abstract contract CodeVerifier is Script {
    struct Ref {
        uint256 length;
        uint256 start;
    }

    /// @notice Whether `a`'s code is a build of `source:name` (an artifact of `out/`), immutables aside.
    function matchesBuild(address a, string memory source, string memory name) public view returns (bool) {
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/out/", source, "/", name, ".json"));
        bytes memory expected = vm.parseJsonBytes(json, ".deployedBytecode.object");
        bytes memory live = a.code;
        if (live.length != expected.length || live.length == 0) return false;
        if (vm.keyExistsJson(json, ".deployedBytecode.immutableReferences")) {
            string[] memory ids = vm.parseJsonKeys(json, ".deployedBytecode.immutableReferences");
            for (uint256 i = 0; i < ids.length; i++) {
                Ref[] memory refs = abi.decode(
                    vm.parseJson(json, string.concat(".deployedBytecode.immutableReferences.", ids[i])), (Ref[])
                );
                for (uint256 k = 0; k < refs.length; k++) {
                    for (uint256 b = 0; b < refs[k].length; b++) {
                        expected[refs[k].start + b] = live[refs[k].start + b];
                    }
                }
            }
        }
        return keccak256(expected) == keccak256(live);
    }

    function _word(address a, string memory sig) internal view returns (address) {
        (bool ok, bytes memory ret) = a.staticcall(abi.encodeWithSignature(sig));
        return ok && ret.length >= 32 ? address(uint160(uint256(bytes32(ret)))) : address(0); // its first word
    }

    function _check(address a, string memory source, string memory name) internal view returns (bool ok) {
        ok = matchesBuild(a, source, name);
        console2.log(ok ? "ok      " : "MISMATCH", name, a);
    }

    /// @notice Checks the transfer app's delegate graph from its implementation (the ICS20 proxy's) and IBCAdmin's
    /// from its executor: every contract a build of its source, every delegate address the one its holder records.
    function verifyGraph(address ics20Implementation, address ibcAdmin) public view returns (bool all) {
        all = _check(ics20Implementation, "GnoICS20Transfer.sol", "GnoICS20Transfer");
        address controls = _word(ics20Implementation, "CONTROLS()");
        all = _check(controls, "GnoICS20Controls.sol", "GnoICS20Controls") && all;
        address reconcile = _word(controls, "RECONCILE()");
        all = _check(reconcile, "GnoICS20Reconcile.sol", "GnoICS20Reconcile") && all;
        all = _check(_word(reconcile, "EVIDENCE()"), "GnoICS20Evidence.sol", "GnoICS20Evidence") && all;
        all = _check(ibcAdmin, "IBCAdmin.sol", "IBCAdmin") && all;
        address exec = _word(ibcAdmin, "exec()");
        all = _check(exec, "IBCAdminExec.sol", "IBCAdminExec") && all;
        all = _check(_word(exec, "checks()"), "IBCAdminChecks.sol", "IBCAdminChecks") && all;
        all = _check(_word(exec, "recoveryModule()"), "IBCAdminRecovery.sol", "IBCAdminRecovery") && all;
        all = _check(_word(exec, "setupCheck()"), "IBCAdminSetupCheck.sol", "IBCAdminSetupCheck") && all;
        all = _check(_word(exec, "frozenClient()"), "FrozenLightClient.sol", "FrozenLightClient") && all;
    }
}
