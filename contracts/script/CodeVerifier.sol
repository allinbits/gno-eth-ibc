// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { IIBCAdmin } from "../src/interfaces/IIBCAdmin.sol";

interface IAccessManagedLike {
    function authority() external view returns (address);
}

interface IRouterLike {
    function getIBCApp(string calldata portId) external view returns (address);
}

interface IBCAdminLike {
    function deployer() external view returns (address);
    function exec() external view returns (address, bytes32);
    function govClient() external view returns (string memory);
    function gnoChainId() external view returns (string memory);
    function recoveryConfig() external view returns (IIBCAdmin.RecoveryConfig memory);
}

/// @notice Checks deployed runtime code against a reproducible build of the named source (ADR §6.12, the T5 watch
/// tool). No byte of the deployed code is taken on trust: each contract is rebuilt, in the verifier's own simulation,
/// by running its build's creation code at its own address with the constructor arguments the system's graph calls
/// for, and the result must equal the deployed code byte for byte. So every immutable is checked against its
/// constructor relationship: a module's recorded own address (`_self`, UUPS's `__self`) is its address, its bindings
/// and dependencies are the graph's actual contracts, and every recorded code hash is that dependency's live code
/// hash. An executor is rebuilt with its creation nonce, so the modules it deploys come out at their recorded
/// addresses and are compared too. Configuration values with no relationship to check (IBCAdmin's deployer and its
/// recovery settings) are printed, for comparison with the deployment plan. Every rebuild is rolled back.
///
/// Two uses: `verifyLive` checks what runs now, read from the chain (the proxies' live implementation slots, the
/// beacons' implementations, IBCAdmin's installed executor), never from a deployment file; `verifyPending` checks a
/// recorded kind 7 or kind 9 decision's candidate before it matures: the decision must be the expected one (its
/// hash, which the watcher computes from gno.land's envelope), name the expected candidate, pin its code hash, and the
/// candidate's whole delegate graph must rebuild to its deployed code.
abstract contract CodeVerifier is Script {
    /// @notice ERC-1967's implementation slot.
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    uint8 internal constant KIND_UPGRADE = 7;
    uint8 internal constant KIND_HANDOVER = 9;

    /// @notice Whether `a`'s code is exactly what `artifact`'s creation code, run at `a` with `args` (by `from`, with
    /// `a`'s nonce at `nonce` when non-zero), produces. The contracts it creates are compared too: `created` lists
    /// their addresses, emptied before the rebuild so that it can place them there again. Rolled back.
    function rebuilds(
        address a,
        string memory artifact,
        bytes memory args,
        address from,
        uint64 nonce,
        address[] memory created
    )
        public
        returns (bool same)
    {
        bytes memory live = a.code;
        if (live.length == 0) return false;
        bytes[] memory liveCreated = new bytes[](created.length);
        for (uint256 i = 0; i < created.length; i++) {
            liveCreated[i] = created[i].code;
        }
        uint256 snap = vm.snapshotState();
        for (uint256 i = 0; i < created.length; i++) {
            vm.etch(created[i], "");
            vm.setNonceUnsafe(created[i], 0);
        }
        if (nonce != 0) vm.setNonceUnsafe(a, nonce);
        vm.etch(a, abi.encodePacked(vm.getCode(artifact), args));
        if (from != address(0)) vm.prank(from);
        (bool ok, bytes memory runtime) = a.call("");
        same = ok && keccak256(runtime) == keccak256(live);
        for (uint256 i = 0; same && i < created.length; i++) {
            same = keccak256(created[i].code) == keccak256(liveCreated[i]);
        }
        vm.revertToState(snap);
    }

    function _word(address a, string memory sig) internal view returns (address) {
        (bool ok, bytes memory ret) = a.staticcall(abi.encodeWithSignature(sig));
        return ok && ret.length >= 32 ? address(uint160(uint256(bytes32(ret)))) : address(0); // its first word
    }

    function _check(address a, string memory artifact, bytes memory args) internal returns (bool ok) {
        ok = rebuilds(a, artifact, args, address(0), 0, new address[](0));
        console2.log(ok ? "ok      " : "MISMATCH", artifact, a);
    }

    /// @notice The live implementation of an ERC-1967 proxy, read from its slot.
    function implementationOf(address proxy) public view returns (address) {
        return address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT))));
    }

    /// @notice The transfer app's graph from an implementation: the fork, its controls, reconciliation and evidence,
    /// each rebuilt with the next one as its dependency.
    function verifyTransfer(address impl) public returns (bool all) {
        address controls = _word(impl, "CONTROLS()");
        address reconcile = _word(controls, "RECONCILE()");
        address evidence = _word(reconcile, "EVIDENCE()");
        all = _check(impl, "GnoICS20Transfer.sol:GnoICS20Transfer", abi.encode(controls));
        all = _check(controls, "GnoICS20Controls.sol:GnoICS20Controls", abi.encode(reconcile)) && all;
        all = _check(reconcile, "GnoICS20Reconcile.sol:GnoICS20Reconcile", abi.encode(evidence)) && all;
        all = _check(evidence, "GnoICS20Evidence.sol:GnoICS20Evidence", "") && all;
    }

    /// @notice An executor bound to `router`, `accessManager` and `ics20`: rebuilt from its creation nonce, with the
    /// four modules it deploys at the addresses it records.
    function verifyExec(address exec, address router, address accessManager, address ics20) public returns (bool ok) {
        address[] memory created = new address[](4);
        created[0] = _word(exec, "frozenClient()");
        created[1] = _word(exec, "setupCheck()");
        created[2] = _word(exec, "checks()");
        created[3] = _word(exec, "recoveryModule()");
        ok = rebuilds(
            exec, "IBCAdminExec.sol:IBCAdminExec", abi.encode(router, accessManager, ics20), address(0), 1, created
        );
        console2.log(ok ? "ok      " : "MISMATCH", "IBCAdminExec.sol:IBCAdminExec (and its four modules)", exec);
    }

    /// @notice The system around IBCAdmin, from the router's own registry: IBCAdmin must be the router's `ibcgov`
    /// app, the transfer app its `transfer` app, and the access manager the router's authority.
    function _system(address ibcAdmin) internal view returns (address router, address am, address ics20) {
        router = _word(ibcAdmin, "router()");
        require(IRouterLike(router).getIBCApp("ibcgov") == ibcAdmin, "IBCAdmin is not the router's ibcgov app");
        ics20 = IRouterLike(router).getIBCApp("transfer");
        am = IAccessManagedLike(router).authority();
    }

    /// @notice IBCAdmin rebuilt with the system's router, access manager and transfer app, its installed executor,
    /// its deployer and its recovery settings (the configuration values, printed).
    function verifyAdmin(address ibcAdmin) public returns (bool ok) {
        (address router, address am, address ics20) = _system(ibcAdmin);
        IBCAdminLike a = IBCAdminLike(ibcAdmin);
        (address exec,) = a.exec();
        address[4] memory seats = [address(0xA1), address(0xA2), address(0xA3), address(0xA4)];
        address[2] memory watch = [address(0xB1), address(0xB2)];
        IIBCAdmin.RecoveryConfig memory rc = a.recoveryConfig();
        bytes memory config =
            abi.encode(IBCAdminConfigLike(router, am, ics20, exec, a.govClient(), a.gnoChainId(), seats, watch, rc));
        ok = rebuilds(ibcAdmin, "IBCAdmin.sol:IBCAdmin", config, a.deployer(), 0, new address[](0));
        console2.log(ok ? "ok      " : "MISMATCH", "IBCAdmin.sol:IBCAdmin", ibcAdmin);
        console2.log("  deployer", a.deployer());
        console2.log("  recovery delay, threshold, cancel threshold", rc.delay, rc.threshold, rc.cancelThreshold);
        console2.log("  recovery silence, hold period", rc.silence, rc.holdPeriod);
    }

    /// @notice What runs now, from the chain alone: the transfer proxy's and the router proxy's live implementations,
    /// the escrow and voucher beacons' implementations, IBCAdmin and its installed executor, each graph complete.
    function verifyLive(address ibcAdmin) public returns (bool all) {
        (address router, address am, address ics20) = _system(ibcAdmin);
        all = verifyTransfer(implementationOf(ics20));
        all = _check(implementationOf(router), "ICS26Router.sol:ICS26Router", "") && all;
        all = _check(_word(_word(ics20, "getEscrowBeacon()"), "implementation()"), "Escrow.sol:Escrow", "") && all;
        all = _check(_word(_word(ics20, "getIBCERC20Beacon()"), "implementation()"), "IBCERC20.sol:IBCERC20", "") && all;
        all = verifyAdmin(ibcAdmin) && all;
        all = verifyExec(_word(ibcAdmin, "exec()"), router, am, ics20) && all;
    }

    /// @notice A pending kind 7 or kind 9 decision of the current epoch, before it matures: it must be the expected
    /// decision (`expectedHash`), name `candidate` as the implementation or executor it installs, pin `candidate`'s
    /// live code hash, and `candidate`'s whole graph must rebuild to its deployed code (a kind 7 by the proxy it
    /// upgrades; a kind 9 bound to IBCAdmin's system).
    function verifyPending(address ibcAdmin, uint64 seq, bytes32 expectedHash, address candidate)
        public
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
        (address router, address am, address ics20) = _system(ibcAdmin);
        if (d.kind == KIND_HANDOVER) {
            (address x, bytes32 codeHash,) = abi.decode(d.params, (address, bytes32, bytes));
            if (x != candidate || x.codehash != codeHash) {
                console2.log("MISMATCH kind 9 candidate or its pinned hash", x);
                return false;
            }
            return verifyExec(x, router, am, ics20);
        }
        if (d.kind == KIND_UPGRADE) {
            (address proxy, address impl, bytes32 codeHash,) = abi.decode(d.params, (address, address, bytes32, bytes));
            if (impl != candidate || impl.codehash != codeHash) {
                console2.log("MISMATCH kind 7 candidate or its pinned hash", impl);
                return false;
            }
            if (proxy == ics20) return verifyTransfer(impl);
            if (proxy == router) return _check(impl, "ICS26Router.sol:ICS26Router", "");
            if (proxy == _word(ics20, "getEscrowBeacon()")) return _check(impl, "Escrow.sol:Escrow", "");
            if (proxy == _word(ics20, "getIBCERC20Beacon()")) return _check(impl, "IBCERC20.sol:IBCERC20", "");
            console2.log("MISMATCH kind 7 of an unknown proxy", proxy);
            return false;
        }
        console2.log("MISMATCH not a kind 7 or 9, seq", seq);
        return false;
    }
}

/// @notice IBCAdmin's constructor argument, field for field (IBCAdmin.Config).
struct IBCAdminConfigLike {
    address router;
    address accessManager;
    address ics20;
    address exec;
    string govClientId;
    string gnoChainId;
    address[4] seats;
    address[2] watch;
    IIBCAdmin.RecoveryConfig recovery;
}
