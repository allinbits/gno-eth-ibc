// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { BeaconProxy } from "@openzeppelin-contracts/proxy/beacon/BeaconProxy.sol";
import { GnoLightClient } from "../../src/GnoLightClient.sol";
import { GnoVoucher } from "../../src/GnoVoucher.sol";
import { IGnoLightClientMsgs as Msgs } from "../../src/msgs/IGnoLightClientMsgs.sol";
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

/// @notice A plain forwarding proxy: mutable code indirection (its target could be swapped by whoever deploys it).
contract ForwardingProxy {
    address internal immutable target;

    constructor(address t) {
        target = t;
    }

    fallback() external payable {
        address t = target;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), t, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch ok
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }
}

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
    function test_r10_1_deploymentMatchesTheBuild() public {
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
        assertFalse(verifier.verifyTransfer(d.ics20Implementation));
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
        assertFalse(verifier.verifyTransfer(fork), "the build check");
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
        // on chain, since r12, the executor's bindings answer nothing through a proxy (its recorded own address is the
        // implementation's), so kind 9 is spent too
        _skip(7 days);
        admin.execute(seq);
        assertEq(admin.decision(admin.epoch(), seq).state, S.SPENT, "refused on chain");
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

    // ================================================================================================ round 12 ==

    /// @notice r12 #3, the runbook's response to a failed verification: kind 1 with the range [(s, s)] cancels the
    /// pending kind 7 at s (kind 2 would only unpause); its encoding is the `kind1-cancel` vector's.
    function test_r12_3_runbookCancel_cancelsAPendingKind7() public {
        GnoICS20Controls controls =
            new GnoICS20Controls(address(new GnoICS20Reconcile(address(new GnoICS20Evidence()))));
        address fork = address(new GnoICS20Transfer(address(controls)));
        uint64 s = admin.lastSeq() + 1;
        _recvGov(_env(s, S.KIND_UPGRADE, P.upgrade(address(ics20), fork, fork.codehash, "")));
        P.Range[] memory ranges = new P.Range[](1);
        ranges[0] = P.Range(s, s);
        bytes memory cancel = _env(s + 1, S.KIND_CANCEL, P.cancel(ranges));
        // the vector's layout: header, then abi.encode of the ranges array
        assertEq(uint8(cancel[13]), 1, "kind 1");
        assertEq(cancel.length, 14 + 32 * 4);
        _recvGov(cancel);
        assertTrue(admin.isTombstoned(admin.epoch(), s));
        _skip(7 days + 1);
        admin.execute(s);
        assertEq(admin.decision(admin.epoch(), s).state, S.CANCELLED);
        assertEq(verifier.implementationOf(address(ics20)), d.ics20Implementation, "not installed");
    }

    struct Ref {
        uint256 length;
        uint256 start;
    }

    /// @notice The round 10 check, kept here to show the gap: the build's bytes with every immutable byte taken from
    /// the deployed code, unvalidated.
    function _splicedMatch(address a, string memory source, string memory name) internal view returns (bool) {
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/out/", source, "/", name, ".json"));
        bytes memory expected = vm.parseJsonBytes(json, ".deployedBytecode.object");
        bytes memory live = a.code;
        if (live.length != expected.length) return false;
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
        return keccak256(expected) == keccak256(live);
    }

    /// @notice `code` with every 32-byte word holding `from` (as an address) replaced by `to`: an immutable patched.
    function _patch(bytes memory code, address from, address to) internal pure returns (bytes memory out, uint256 n) {
        out = code;
        bytes32 f = bytes32(uint256(uint160(from)));
        bytes32 t = bytes32(uint256(uint160(to)));
        for (uint256 i = 0; i + 32 <= out.length; i++) {
            bytes32 w;
            assembly {
                w := mload(add(add(out, 32), i))
            }
            if (w == f) {
                assembly {
                    mstore(add(add(out, 32), i), t)
                }
                n++;
                i += 31;
            }
        }
    }

    /// @notice r12 #1: a pending kind 7 whose controls module is the build's code with one immutable altered (its
    /// recorded own address set to the transfer proxy, so every delegated call would revert `NotDelegated`). Every
    /// other byte is the build's. The verification rebuilds the module at its address and refuses it; on chain, kind 7
    /// refuses it too (`gnoSelf` must be the module's address).
    function test_r12_1_pendingKind7_alteredImmutable_refused() public {
        GnoICS20Controls genuine = new GnoICS20Controls(address(new GnoICS20Reconcile(address(new GnoICS20Evidence()))));
        (bytes memory patched, uint256 n) = _patch(address(genuine).code, address(genuine), address(ics20));
        assertGt(n, 0, "the immutable holding the module's own address, at each of its uses");
        address altered = address(0xA17E4ED);
        vm.etch(altered, patched);
        assertEq(GnoICS20Controls(altered).gnoSelf(), address(ics20));
        assertTrue(_splicedMatch(altered, "GnoICS20Controls.sol", "GnoICS20Controls"), "the round 10 check passed it");
        address fork = address(new GnoICS20Transfer(altered));
        uint64 seq = admin.lastSeq() + 1;
        bytes memory env = _env(seq, S.KIND_UPGRADE, P.upgrade(address(ics20), fork, fork.codehash, ""));
        _recvGov(env);
        assertFalse(verifier.verifyPending(address(admin), seq, keccak256(env), fork), "refused before maturity");
        _skip(7 days + 1);
        admin.execute(seq);
        assertEq(admin.decision(admin.epoch(), seq).state, S.SPENT, "refused on chain");
        assertEq(verifier.implementationOf(address(ics20)), d.ics20Implementation);
    }

    /// @notice r12 #1, the executor: a pending kind 9 whose executor is the build's code with its recorded own address
    /// altered. Refused by the verification (rebuilt at its address with its creation nonce) and on chain (its
    /// bindings answer nothing).
    function test_r12_1_pendingKind9_alteredImmutable_refused() public {
        IBCAdminExec genuine = new IBCAdminExec(address(router), d.accessManager, address(ics20));
        (bytes memory patched, uint256 n) = _patch(address(genuine).code, address(genuine), address(admin));
        assertGt(n, 0);
        address altered = address(0xE7EC);
        vm.etch(altered, patched);
        uint64 seq = admin.lastSeq() + 1;
        bytes memory env = _env(seq, S.KIND_HANDOVER, P.handover(altered, altered.codehash, ""));
        _recvGov(env);
        assertFalse(verifier.verifyPending(address(admin), seq, keccak256(env), altered));
        _skip(7 days + 1);
        admin.execute(seq);
        assertEq(admin.decision(admin.epoch(), seq).state, S.SPENT);
        // the genuine executor, rebuilt at its address with its creation nonce and modules, passes
        bytes memory env2 = _env(seq + 1, S.KIND_HANDOVER, P.handover(address(genuine), address(genuine).codehash, ""));
        _recvGov(env2);
        assertTrue(verifier.verifyPending(address(admin), seq + 1, keccak256(env2), address(genuine)));
    }

    /// @notice r12 #1: a recorded dependency hash that is not its dependency's live hash fails the rebuild (a module
    /// built against other code, then that code replaced at the same address).
    function test_r12_1_staleDependencyHash_refused() public {
        address evidence = address(new GnoICS20Evidence());
        address reconcile = address(new GnoICS20Reconcile(evidence));
        assertTrue(
            verifier.rebuilds(
                reconcile,
                "GnoICS20Reconcile.sol:GnoICS20Reconcile",
                abi.encode(evidence),
                address(0),
                0,
                new address[](0)
            )
        );
        vm.etch(evidence, address(new MockLightClient()).code);
        assertFalse(
            verifier.rebuilds(
                reconcile,
                "GnoICS20Reconcile.sol:GnoICS20Reconcile",
                abi.encode(evidence),
                address(0),
                0,
                new address[](0)
            )
        );
    }

    // ============================================== design r2 #2: vouchers, verifiers and their pending kinds ==

    function _gnoClient() internal returns (GnoLightClient) {
        return new GnoLightClient(
            Msgs.ClientState("gnoland-9", 0, 5, Msgs.TrustThreshold(1, 1), 1 days, 10, false),
            Msgs.ConsensusState(1, bytes32(uint256(1)), bytes32(uint256(2)))
        );
    }

    /// @notice A voucher rebuilds from its own name, symbol, decimals and denom, bound to the transfer app; one bound
    /// elsewhere, or behind a proxy, fails.
    function test_d2_vouchers_rebuiltAndBound() public {
        assertTrue(verifier.verifyVoucher(address(ugnot), address(ics20)), "the launch voucher");
        assertFalse(verifier.verifyVoucher(address(ugnot), address(0xBEEF)), "bound to another transfer app");
        GnoVoucher impl = new GnoVoucher("x", "X", 6, address(ics20), "transfer/client-0/ux");
        address proxied = address(new ForwardingProxy(address(impl)));
        assertFalse(verifier.verifyVoucher(proxied, address(ics20)), "a voucher behind a proxy");
    }

    /// @notice A GnoLightClient rebuilds whatever its trusted state; a proxy to one, or other verifier code, fails.
    function test_d2_lightClients_rebuilt_proxiesRefused() public {
        GnoLightClient lc = _gnoClient();
        assertTrue(verifier.verifyLightClient(address(lc)));
        assertFalse(verifier.verifyLightClient(address(new ForwardingProxy(address(lc)))), "a verifier behind a proxy");
        assertFalse(verifier.verifyLightClient(address(new MockLightClient())), "other verifier code");
    }

    /// @notice Pending kinds 5 and 6 are verified before they mature: the decision's hash, its candidate, the pinned
    /// hash and the candidate's build.
    function test_d2_pendingKinds5And6_verified() public {
        GnoLightClient lc = _gnoClient();
        address proxied = address(new ForwardingProxy(address(lc)));
        uint64 seq = admin.lastSeq() + 1;
        bytes memory e1 = _env(
            seq, S.KIND_CLIENT, P.client(1, "gnoland-9", "ethereum-9", _prefix(), address(lc), address(lc).codehash)
        );
        bytes memory e2 =
            _env(seq + 1, S.KIND_CLIENT, P.client(1, "gnoland-8", "ethereum-8", _prefix(), proxied, proxied.codehash));
        _recvGov(e1);
        _recvGov(e2);
        assertTrue(verifier.verifyPending(address(admin), seq, keccak256(e1), address(lc)), "a genuine verifier");
        assertFalse(verifier.verifyPending(address(admin), seq + 1, keccak256(e2), proxied), "a proxy-backed verifier");
        GnoVoucher v = new GnoVoucher("Atom", "ATOM", 6, address(ics20), "transfer/client-0/uatom");
        GnoVoucher other = new GnoVoucher("Atom", "ATOM", 6, address(0xBEEF), "transfer/client-0/uatom");
        bytes memory e3 = _env(seq + 2, S.KIND_VOUCHER, P.voucher(clientId, "uatom", address(v), address(v).codehash));
        bytes memory e4 =
            _env(seq + 3, S.KIND_VOUCHER, P.voucher(clientId, "uatom", address(other), address(other).codehash));
        _recvGov(e3);
        _recvGov(e4);
        assertTrue(verifier.verifyPending(address(admin), seq + 2, keccak256(e3), address(v)), "a genuine voucher");
        assertFalse(
            verifier.verifyPending(address(admin), seq + 3, keccak256(e4), address(other)), "bound to another app"
        );
        assertFalse(verifier.verifyPending(address(admin), seq + 2, keccak256(e3), address(other)), "other candidate");
    }
}
