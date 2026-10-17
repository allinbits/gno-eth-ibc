// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { IIBCAdmin } from "../src/interfaces/IIBCAdmin.sol";

/// @notice Checks deployed runtime code against a reproducible build of the named source (ADR §6.12, the T5 watch
/// tool): the deployed code must equal the built `deployedBytecode`, every byte outside the immutables the compiler
/// lists. The immutables are then followed: a delegate module's address recorded in one contract is checked in turn
/// against its own build, so a module that is a proxy (whose code is a proxy's, whatever it delegates to) never
/// passes. On-chain pinning fixes code hashes; only this check ties a hash to the source.
///
/// Two uses: `verifyLive` checks what runs now, read from the chain (the proxies' live implementation slots, the
/// beacons' implementations, IBCAdmin's installed executor), never from a deployment file; `verifyPending` checks a
/// recorded kind 7 or kind 9 decision's candidate before it matures: the decision must be the expected one (its
/// hash, which the watcher computes from gno.land's envelope), name the expected candidate, pin its code hash, and the
/// candidate's whole delegate graph must be a build of its source.
abstract contract CodeVerifier is Script {
    struct Ref {
        uint256 length;
        uint256 start;
    }

    /// @notice ERC-1967's implementation slot.
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    uint8 internal constant KIND_UPGRADE = 7;
    uint8 internal constant KIND_HANDOVER = 9;

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

    /// @notice The live implementation of an ERC-1967 proxy, read from its slot.
    function implementationOf(address proxy) public view returns (address) {
        return address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT))));
    }

    /// @notice The transfer app's graph from an implementation: the fork, its controls, reconciliation and evidence.
    function verifyTransfer(address impl) public view returns (bool all) {
        all = _check(impl, "GnoICS20Transfer.sol", "GnoICS20Transfer");
        address controls = _word(impl, "CONTROLS()");
        all = _check(controls, "GnoICS20Controls.sol", "GnoICS20Controls") && all;
        address reconcile = _word(controls, "RECONCILE()");
        all = _check(reconcile, "GnoICS20Reconcile.sol", "GnoICS20Reconcile") && all;
        all = _check(_word(reconcile, "EVIDENCE()"), "GnoICS20Evidence.sol", "GnoICS20Evidence") && all;
    }

    /// @notice IBCAdmin's executor graph: the executor and every module it records.
    function verifyExec(address exec) public view returns (bool all) {
        all = _check(exec, "IBCAdminExec.sol", "IBCAdminExec");
        all = _check(_word(exec, "checks()"), "IBCAdminChecks.sol", "IBCAdminChecks") && all;
        all = _check(_word(exec, "recoveryModule()"), "IBCAdminRecovery.sol", "IBCAdminRecovery") && all;
        all = _check(_word(exec, "setupCheck()"), "IBCAdminSetupCheck.sol", "IBCAdminSetupCheck") && all;
        all = _check(_word(exec, "frozenClient()"), "FrozenLightClient.sol", "FrozenLightClient") && all;
    }

    /// @notice What runs now, from the chain alone: the transfer proxy's and the router proxy's live implementations,
    /// the escrow and voucher beacons' implementations, IBCAdmin and its installed executor, each graph complete.
    function verifyLive(address ibcAdmin) public view returns (bool all) {
        address ics20 = _word(ibcAdmin, "ics20()");
        address router = _word(ibcAdmin, "router()");
        all = verifyTransfer(implementationOf(ics20));
        all = _check(implementationOf(router), "ICS26Router.sol", "ICS26Router") && all;
        all = _check(_word(_word(ics20, "getEscrowBeacon()"), "implementation()"), "Escrow.sol", "Escrow") && all;
        all = _check(_word(_word(ics20, "getIBCERC20Beacon()"), "implementation()"), "IBCERC20.sol", "IBCERC20") && all;
        all = _check(ibcAdmin, "IBCAdmin.sol", "IBCAdmin") && all;
        all = verifyExec(_word(ibcAdmin, "exec()")) && all;
    }

    /// @notice A pending kind 7 or kind 9 decision of the current epoch, before it matures: it must be the expected
    /// decision (`expectedHash`), name `candidate` as the implementation or executor it installs, pin `candidate`'s
    /// live code hash, and `candidate`'s whole graph must be a build of its source (a kind 7 by the proxy it
    /// upgrades).
    function verifyPending(
        address ibcAdmin,
        uint64 seq,
        bytes32 expectedHash,
        address candidate
    )
        public
        view
        returns (bool)
    {
        (bool ok, bytes memory ret) = ibcAdmin.staticcall(abi.encodeWithSignature("epoch()"));
        require(ok, "epoch");
        uint32 ep = abi.decode(ret, (uint32));
        (ok, ret) = ibcAdmin.staticcall(abi.encodeWithSignature("decision(uint32,uint64)", ep, seq));
        require(ok, "decision");
        IIBCAdmin.Decision memory d = abi.decode(ret, (IIBCAdmin.Decision));
        if (d.hash != expectedHash) {
            console2.log("MISMATCH decision hash, seq", seq);
            return false;
        }
        if (d.kind == KIND_HANDOVER) {
            (address x, bytes32 codeHash,) = abi.decode(d.params, (address, bytes32, bytes));
            if (x != candidate || x.codehash != codeHash) {
                console2.log("MISMATCH kind 9 candidate or its pinned hash", x);
                return false;
            }
            return verifyExec(x);
        }
        if (d.kind == KIND_UPGRADE) {
            (address proxy, address impl, bytes32 codeHash,) = abi.decode(d.params, (address, address, bytes32, bytes));
            if (impl != candidate || impl.codehash != codeHash) {
                console2.log("MISMATCH kind 7 candidate or its pinned hash", impl);
                return false;
            }
            address ics20 = _word(ibcAdmin, "ics20()");
            if (proxy == ics20) return verifyTransfer(impl);
            if (proxy == _word(ibcAdmin, "router()")) return _check(impl, "ICS26Router.sol", "ICS26Router");
            if (proxy == _word(ics20, "getEscrowBeacon()")) return _check(impl, "Escrow.sol", "Escrow");
            if (proxy == _word(ics20, "getIBCERC20Beacon()")) return _check(impl, "IBCERC20.sol", "IBCERC20");
            console2.log("MISMATCH kind 7 of an unknown proxy", proxy);
            return false;
        }
        console2.log("MISMATCH not a kind 7 or 9, seq", seq);
        return false;
    }
}
