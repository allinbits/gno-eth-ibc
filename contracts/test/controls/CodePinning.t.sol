// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { BeaconProxy } from "@openzeppelin-contracts/proxy/beacon/BeaconProxy.sol";
import { UpgradeableBeacon } from "@openzeppelin-contracts/proxy/beacon/UpgradeableBeacon.sol";

import { GnoICS20Transfer } from "../../src/GnoICS20Transfer.sol";
import { IBCAdminExec } from "../../src/admin/IBCAdminExec.sol";
import { GnoICS20Controls } from "../../src/transfer/GnoICS20Controls.sol";
import { GnoICS20Reconcile } from "../../src/transfer/GnoICS20Reconcile.sol";
import { GnoICS20Evidence } from "../../src/transfer/GnoICS20Evidence.sol";
import { IGnoICS20ControlsTypes as T } from "../../src/interfaces/IGnoICS20Controls.sol";
import { IBCAdminStorage as S } from "../../src/admin/IBCAdminStorage.sol";
import { GovParams as P } from "../utils/GovParams.sol";
import { MockLightClient } from "../utils/MockLightClient.sol";
import { CodeVerifier } from "../../script/CodeVerifier.sol";
import { ControlsFixture } from "./ControlsFixture.sol";

contract Verifier is CodeVerifier { }

/// @notice Round 10 #1: the delegate graph is pinned transitively. Each implementation and module records its
/// delegates' code hashes at construction, so the implementation's pinned hash fixes the whole graph; a module whose
/// code changes is refused on every delegated call and at kind 7. A module that is a proxy keeps its own hash
/// whatever it delegates to: only the build verification (script/VerifyCodehashes.s.sol) catches it.
contract CodePinningTest is ControlsFixture {
    Verifier internal verifier;

    function setUp() public override {
        super.setUp();
        verifier = new Verifier();
    }

    function _prefix() internal pure returns (bytes[] memory p) {
        p = new bytes[](2);
        p[0] = "main";
        p[1] = "/pv/vm:gno.land/r/aib/ibc/core:";
    }

    /// @notice The deployment matches a build of its sources, delegates included.
    function test_r10_1_deploymentMatchesTheBuild() public view {
        assertTrue(verifier.verifyLive(address(admin)));
    }

    /// @notice A module whose code is swapped (the same address, other code) is refused on every delegated call.
    function test_r10_1_swappedModule_refusedOnEveryDelegatedCall() public {
        address reconcile = GnoICS20Controls(d.ics20Controls).RECONCILE();
        assertEq(ctl.openRecords(clientId), 0); // through the controls
        vm.etch(d.ics20Controls, address(new MockLightClient()).code);
        vm.expectRevert(T.GnoBadModule.selector);
        ctl.openRecords(clientId);
        // a swapped reconciliation module behind genuine controls is refused at the controls' hop
        vm.etch(d.ics20Controls, address(new GnoICS20Controls(reconcile)).code);
        vm.etch(reconcile, address(new MockLightClient()).code);
        vm.expectRevert(T.GnoBadModule.selector);
        ctl.incidents(clientId);
        assertFalse(verifier.matchesBuild(reconcile, "GnoICS20Reconcile.sol", "GnoICS20Reconcile"));
    }

    /// @notice Kind 7 refuses a candidate whose module's code is not the one it recorded.
    function test_r10_1_kind7_refusesAModuleWhoseCodeChanged() public {
        GnoICS20Controls controls =
            new GnoICS20Controls(address(new GnoICS20Reconcile(address(new GnoICS20Evidence()))));
        address fork = address(new GnoICS20Transfer(address(controls)));
        uint64 seq = admin.lastSeq() + 1;
        _recvGov(_env(seq, S.KIND_UPGRADE, P.upgrade(address(ics20), fork, fork.codehash, "")));
        _skip(7 days);
        // other controls, answering the same versions: only the recorded hash tells
        address other = address(new GnoICS20Controls(address(new GnoICS20Reconcile(address(new GnoICS20Evidence())))));
        vm.etch(address(controls), other.code);
        admin.execute(seq);
        assertEq(admin.decision(admin.epoch(), seq).state, S.SPENT);
    }

    /// @notice A beacon-proxy module: its hash is the proxy's, so kind 7 accepts it as governance pinned it, and the
    /// beacon's owner can change what it runs without changing any hash. The build verification refuses it.
    function test_r10_1_beaconProxyModule_caughtOnlyByTheBuildVerification() public {
        GnoICS20Controls genuine = new GnoICS20Controls(address(new GnoICS20Reconcile(address(new GnoICS20Evidence()))));
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(genuine), address(this));
        address proxied = address(new BeaconProxy(address(beacon), ""));
        address fork = address(new GnoICS20Transfer(proxied));
        bytes32 recorded = GnoICS20Transfer(fork).CONTROLS_HASH();
        assertEq(recorded, proxied.codehash);
        beacon.upgradeTo(address(new GnoICS20Controls(address(new GnoICS20Reconcile(address(new GnoICS20Evidence()))))));
        assertEq(proxied.codehash, recorded, "the proxy's hash never changes");
        assertFalse(verifier.matchesBuild(proxied, "GnoICS20Controls.sol", "GnoICS20Controls"), "the build check");
    }

    // ================================================================================================ round 11 ==

    /// @notice r11 #3: the verification reads the live implementation slot, not the deployment file: an
    /// implementation installed behind the file's back is caught.
    function test_r11_3_liveImplementationSlot_checked() public {
        assertEq(verifier.implementationOf(address(ics20)), d.ics20Implementation);
        assertTrue(verifier.verifyLive(address(admin)));
        // the proxy now runs other code (the deployment file still names the old implementation)
        address other = address(new MockLightClient());
        vm.store(
            address(ics20),
            bytes32(0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc),
            bytes32(uint256(uint160(other)))
        );
        assertFalse(verifier.verifyLive(address(admin)));
        assertTrue(verifier.verifyTransfer(d.ics20Implementation), "the file's implementation is still a build");
    }

    /// @notice r11 #3, end to end: a pending kind 9 hands over to an executor behind a beacon proxy. On chain it
    /// would pass (its bindings answer through the proxy, its hash is the one governance pinned); the verification of
    /// the pending decision refuses it before it matures. A genuine executor passes; a wrong expected hash or another
    /// candidate fails.
    function test_r11_3_pendingProxyBackedExecutor_refused() public {
        IBCAdminExec genuine = new IBCAdminExec(address(router), d.accessManager, address(ics20));
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(genuine), address(this));
        address proxied = address(new BeaconProxy(address(beacon), ""));
        uint64 seq = admin.lastSeq() + 1;
        bytes memory env = _env(seq, S.KIND_HANDOVER, P.handover(proxied, proxied.codehash, ""));
        _recvGov(env);
        assertEq(admin.decision(admin.epoch(), seq).state, S.PENDING);
        assertFalse(verifier.verifyPending(address(admin), seq, keccak256(env), proxied), "the proxy-backed executor");
        // the genuine executor, pending as well, passes; the checks are of the named decision and candidate
        bytes memory env2 = _env(seq + 1, S.KIND_HANDOVER, P.handover(address(genuine), address(genuine).codehash, ""));
        _recvGov(env2);
        assertTrue(verifier.verifyPending(address(admin), seq + 1, keccak256(env2), address(genuine)));
        assertFalse(verifier.verifyPending(address(admin), seq + 1, keccak256(env), address(genuine)), "other hash");
        assertFalse(verifier.verifyPending(address(admin), seq + 1, keccak256(env2), proxied), "other candidate");
        // on chain, the proxy-backed hand-over would execute: only the verification catches it
        _skip(7 days);
        admin.execute(seq);
        assertEq(admin.decision(admin.epoch(), seq).state, S.EXECUTED, "governance pinned it");
        assertFalse(verifier.verifyLive(address(admin)), "and the live check refuses it after");
    }

    /// @notice r11 #3: a pending kind 7 of the transfer app is checked through its whole graph: a candidate whose
    /// controls module is a beacon proxy fails, a genuine one passes.
    function test_r11_3_pendingKind7_checksTheCandidatesGraph() public {
        GnoICS20Controls genuineControls =
            new GnoICS20Controls(address(new GnoICS20Reconcile(address(new GnoICS20Evidence()))));
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(genuineControls), address(this));
        address proxiedControls = address(new BeaconProxy(address(beacon), ""));
        address bad = address(new GnoICS20Transfer(proxiedControls));
        address good = address(new GnoICS20Transfer(address(genuineControls)));
        uint64 seq = admin.lastSeq() + 1;
        bytes memory e1 = _env(seq, S.KIND_UPGRADE, P.upgrade(address(ics20), bad, bad.codehash, ""));
        bytes memory e2 = _env(seq + 1, S.KIND_UPGRADE, P.upgrade(address(ics20), good, good.codehash, ""));
        _recvGov(e1);
        _recvGov(e2);
        assertFalse(verifier.verifyPending(address(admin), seq, keccak256(e1), bad));
        assertTrue(verifier.verifyPending(address(admin), seq + 1, keccak256(e2), good));
    }
}
