// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IAccessManager } from "@openzeppelin-contracts/access/manager/IAccessManager.sol";
import { UpgradeableBeacon } from "@openzeppelin-contracts/proxy/beacon/UpgradeableBeacon.sol";

import { ICS26Router } from "@eureka/ICS26Router.sol";
import { IICS20Transfer } from "@eureka/interfaces/IICS20Transfer.sol";
import { IICS26RouterMsgs } from "@eureka/msgs/IICS26RouterMsgs.sol";
import { IICS02ClientMsgs } from "@eureka/msgs/IICS02ClientMsgs.sol";
import { Escrow } from "@eureka/utils/Escrow.sol";
import { IBCRolesLib } from "@eureka/utils/IBCRolesLib.sol";

import { GnoICS20Transfer } from "../../src/GnoICS20Transfer.sol";
import { GnoVoucher } from "../../src/GnoVoucher.sol";
import { GnoICS20Controls } from "../../src/transfer/GnoICS20Controls.sol";
import { GnoICS20Reconcile } from "../../src/transfer/GnoICS20Reconcile.sol";
import { GnoICS20Evidence } from "../../src/transfer/GnoICS20Evidence.sol";
import { IGnoICS20Controls, IGnoICS20ControlsTypes as T } from "../../src/interfaces/IGnoICS20Controls.sol";
import { IGuardians } from "../../src/interfaces/IGuardians.sol";
import { IIBCAdmin } from "../../src/interfaces/IIBCAdmin.sol";
import { IBCAdminExec } from "../../src/admin/IBCAdminExec.sol";
import { IBCAdminSetupCheck } from "../../src/admin/IBCAdminSetupCheck.sol";
import { IBCAdmin } from "../../src/admin/IBCAdmin.sol";
import { IBCAdminStorage as S } from "../../src/admin/IBCAdminStorage.sol";
import { GovParams as P } from "../utils/GovParams.sol";
import { MockLightClient } from "../utils/MockLightClient.sol";
import { ControlsFixture } from "./ControlsFixture.sol";

/// @notice Each decision kind of §5.4 end to end (recorded through the router, executed by anyone), with its delay,
/// deferral by flags and holds, the guardian replacement's day-21 rule, the hand-over and the route replacement.
contract IBCAdminKindsTest is ControlsFixture {
    /// @notice Delivers a decision at the next number; returns its number and the ack's status.
    function _decide(uint8 kind, bytes memory params) internal returns (uint64 seq, uint8 status) {
        seq = admin.lastSeq() + 1;
        status = _status(_recvGov(_env(seq, kind, params)));
    }

    function _decidePending(uint8 kind, bytes memory params) internal returns (uint64 seq) {
        uint8 status;
        (seq, status) = _decide(kind, params);
        assertEq(status, S.STATUS_RECORDED, "recorded");
        assertEq(admin.decision(admin.epoch(), seq).state, S.PENDING, "pending");
    }

    function _state(uint64 seq) internal view returns (uint8) {
        return admin.decision(admin.epoch(), seq).state;
    }

    function _executeAfterWeek(uint64 seq) internal {
        _skip(7 days - 1);
        vm.expectRevert();
        admin.execute(seq);
        _skip(1);
        vm.prank(bob); // anyone
        admin.execute(seq);
    }

    function _prefix() internal pure returns (bytes[] memory p) {
        p = new bytes[](2);
        p[0] = "main";
        p[1] = "/pv/vm:gno.land/r/aib/ibc/core:";
    }

    // =============================================================================================== kind 2 ==

    function test_kind2_unpauseRoute_after24h_clearsOnlyEarlierFlags() public {
        vm.prank(G[0]);
        ctl.setRouteFlag(clientId);
        _skip(12);
        uint64 seq = _decidePending(S.KIND_UNPAUSE, P.unpause(1, clientId));
        _skip(12);
        vm.prank(W[0]); // after the recording: stays
        ctl.setRouteFlag(clientId);
        _skip(1 days - 13);
        vm.expectRevert(
            abi.encodeWithSelector(IIBCAdmin.NotMature.selector, admin.decision(1, seq).recordedTime + 1 days)
        );
        admin.execute(seq);
        _skip(1);
        admin.execute(seq);
        IGuardians.Flag[6] memory f = ctl.routeFlags(clientId);
        assertEq(f[0].blockNumber, 0);
        assertTrue(f[4].blockNumber != 0);
    }

    function test_kind2_spentUnderRouteHold() public {
        vm.prank(G[0]);
        ctl.setRouteFlag(clientId);
        vm.prank(G[1]);
        ctl.setRouteFlag(clientId);
        _skip(12);
        uint64 seq = _decidePending(S.KIND_UNPAUSE, P.unpause(1, clientId));
        _skip(1 days);
        admin.execute(seq);
        assertEq(_state(seq), S.SPENT);
        assertTrue(ctl.routePaused(clientId));
    }

    function test_kind2_unpauseAdmin_releasesDeferredDecisions() public {
        uint64 shorten = _decidePending(S.KIND_SETTINGS, P.settings(clientId, 1 days));
        vm.prank(G[2]);
        admin.setFlag();
        _skip(12);
        uint64 unpause = _decidePending(S.KIND_UNPAUSE, P.unpause(2, ""));
        _skip(7 days);
        vm.expectRevert(IIBCAdmin.Deferred.selector);
        admin.execute(shorten);
        admin.execute(unpause); // an unpause is not deferred by flags
        assertEq(admin.flags()[2].blockNumber, 0);
        admin.execute(shorten);
        assertEq(ctl.quarantineSeconds(clientId), 1 days);
    }

    function test_kind2_spentUnderAdminHold() public {
        vm.prank(G[0]);
        admin.setFlag();
        vm.prank(G[3]);
        admin.setFlag();
        _skip(12);
        uint64 seq = _decidePending(S.KIND_UNPAUSE, P.unpause(2, ""));
        _skip(1 days);
        admin.execute(seq);
        assertEq(_state(seq), S.SPENT);
        assertTrue(admin.hold().blockNumber != 0);
    }

    // =============================================================================================== kind 3 ==

    function test_kind3_replacesKeysOnBothObjects() public {
        address fresh = makeAddr("fresh");
        uint64 seq = _decidePending(S.KIND_SEATS, P.seat1(0, fresh));
        _executeAfterWeek(seq);
        assertEq(admin.keys()[0], fresh);
        assertEq(ctl.guardianKeys()[0], fresh);
        vm.expectRevert(IGuardians.UnknownKey.selector);
        vm.prank(G[0]);
        ctl.setRouteFlag(clientId);
        vm.prank(fresh);
        ctl.setRouteFlag(clientId);
        assertTrue(ctl.routePaused(clientId));
    }

    function test_kind3_landsThroughALoneFlag() public {
        uint64 seq = _decidePending(S.KIND_SEATS, P.seat1(4, makeAddr("fresh watch")));
        vm.prank(W[0]);
        admin.setFlag();
        _executeAfterWeek(seq);
        assertEq(_state(seq), S.EXECUTED);
    }

    function test_kind3_throughAHold_noSoonerThanDay21() public {
        vm.prank(G[0]);
        admin.setFlag();
        vm.prank(G[1]);
        admin.setFlag();
        uint256 holdStart = _now();
        _skip(1 days);
        uint64 seq = _decidePending(S.KIND_SEATS, P.seat1(1, makeAddr("fresh")));
        _skip(7 days);
        vm.expectRevert(abi.encodeWithSelector(IIBCAdmin.NotMature.selector, holdStart + 21 days));
        admin.execute(seq);
        vm.warp(holdStart + 21 days);
        admin.execute(seq);
        // the replacement cleared a holder's flag: one guardian flag is left, the hold ends at once
        assertEq(admin.hold().blockNumber, 0);
        assertTrue(admin.flags()[0].blockNumber != 0);
    }

    function test_kind3_otherSevenDayKindsDeferredByHold() public {
        uint64 seq = _decidePending(S.KIND_SETTINGS, P.settings(clientId, 1 days));
        vm.prank(G[0]);
        admin.setFlag();
        vm.prank(G[1]);
        admin.setFlag();
        _skip(30 days);
        vm.expectRevert(IIBCAdmin.Deferred.selector);
        admin.execute(seq);
        // the holders clear their flags: the hold stands until 24 hours after the dip
        vm.prank(G[0]);
        admin.clearFlag();
        vm.prank(G[1]);
        admin.clearFlag();
        vm.expectRevert(IIBCAdmin.Deferred.selector);
        admin.execute(seq);
        _skip(1 days);
        admin.execute(seq);
    }

    function test_kind3_badReplacements_spent() public {
        (, uint8 status) = _decide(S.KIND_SEATS, P.seat1(1, G[1])); // its own current key
        assertEq(status, S.STATUS_SPENT);
        IGuardians.SeatKey[] memory three = new IGuardians.SeatKey[](3);
        three[0] = IGuardians.SeatKey(0, makeAddr("a"));
        three[1] = IGuardians.SeatKey(1, makeAddr("b"));
        three[2] = IGuardians.SeatKey(2, makeAddr("c"));
        (, status) = _decide(S.KIND_SEATS, P.seats(three)); // three guardians at once
        assertEq(status, S.STATUS_SPENT);
        // a key that took another seat by execution time
        uint64 a = _decidePending(S.KIND_SEATS, P.seat1(0, makeAddr("x")));
        uint64 b = _decidePending(S.KIND_SEATS, P.seat1(1, makeAddr("x")));
        _skip(7 days);
        admin.execute(a);
        admin.execute(b);
        assertEq(_state(b), S.SPENT);
    }

    // =============================================================================================== kind 4 ==

    function test_kind4_tighteningAtRecording() public {
        (uint64 seq, uint8 status) =
            _decide(S.KIND_LIMITS, P.limits(clientId, address(ugnot), GNOT_MAX / 2, GNOT_DAY, GNOT_DAY, 0, 0));
        assertEq(status, S.STATUS_RECORDED);
        assertEq(_state(seq), S.EXECUTED);
        assertEq(ctl.limits(clientId, address(ugnot)).limits.maxPerMessage, GNOT_MAX / 2);
    }

    function test_kind4_loosening_sevenDays_deferredByFlag() public {
        uint64 seq =
            _decidePending(S.KIND_LIMITS, P.limits(clientId, address(ugnot), GNOT_MAX * 2, GNOT_DAY, GNOT_DAY, 0, 0));
        vm.prank(W[1]);
        admin.setFlag();
        _skip(7 days);
        vm.expectRevert(IIBCAdmin.Deferred.selector);
        admin.execute(seq);
        vm.prank(W[1]);
        admin.clearFlag();
        admin.execute(seq);
        assertEq(ctl.limits(clientId, address(ugnot)).limits.maxPerMessage, GNOT_MAX * 2);
    }

    function test_kind4_whatLoosens() public {
        // a first setting always waits
        _decidePending(S.KIND_LIMITS, P.limits(clientId, address(usdc), 0, 0, 0, 0, 0));
        _setLimits(clientId, address(usdc), T.Limits(10, 10, 10, 100, 10));
        // dropping the send maximum (0 = none) loosens
        _decidePending(S.KIND_LIMITS, P.limits(clientId, address(usdc), 10, 10, 10, 0, 10));
        // lowering the send minimum loosens
        _decidePending(S.KIND_LIMITS, P.limits(clientId, address(usdc), 10, 10, 10, 100, 9));
        // raising the refund cap loosens
        _decidePending(S.KIND_LIMITS, P.limits(clientId, address(usdc), 10, 10, 11, 100, 10));
        // lowering the send maximum and raising the minimum tighten
        (uint64 seq, uint8 status) = _decide(S.KIND_LIMITS, P.limits(clientId, address(usdc), 10, 10, 10, 50, 20));
        assertEq(status, S.STATUS_RECORDED);
        assertEq(_state(seq), S.EXECUTED);
        // invalid values are spent
        (, status) = _decide(S.KIND_LIMITS, P.limits(clientId, address(usdc), 10, 10, 10, 5, 6));
        assertEq(status, S.STATUS_SPENT);
        (, status) = _decide(S.KIND_LIMITS, P.limits(clientId, address(0), 0, 0, 0, 0, 0));
        assertEq(status, S.STATUS_SPENT);
    }

    function test_kind4_olderLooseningNeverUndoesANewerTightening() public {
        uint64 loosen =
            _decidePending(S.KIND_LIMITS, P.limits(clientId, address(ugnot), GNOT_MAX * 2, GNOT_DAY, GNOT_DAY, 0, 0));
        (uint64 tighten,) = _decide(S.KIND_LIMITS, P.limits(clientId, address(ugnot), 1, GNOT_DAY, GNOT_DAY, 0, 0));
        assertEq(_state(tighten), S.EXECUTED);
        _skip(7 days);
        admin.execute(loosen);
        assertEq(_state(loosen), S.SPENT);
        assertEq(ctl.limits(clientId, address(ugnot)).limits.maxPerMessage, 1);
    }

    function test_kind11_olderShorteningNeverUndoesANewerLengthening() public {
        uint64 shorten = _decidePending(S.KIND_SETTINGS, P.settings(clientId, 1 days));
        _decide(S.KIND_SETTINGS, P.settings(clientId, 14 days));
        _skip(7 days);
        admin.execute(shorten);
        assertEq(_state(shorten), S.SPENT);
        assertEq(ctl.quarantineSeconds(clientId), 14 days);
    }

    function test_starvedExecution_pendsInsteadOfSpending() public {
        GnoVoucher v = new GnoVoucher("Foo", "FOO", 6, address(ics20), "transfer/client-0/ufoo");
        uint64 seq = _decidePending(S.KIND_VOUCHER, P.voucher(clientId, "ufoo", address(v), address(v).codehash));
        _skip(7 days);
        for (uint256 g = 150_000; g < 1_100_000; g += 50_000) {
            (bool ok,) = address(admin).call{ gas: g }(abi.encodeCall(admin.execute, (seq)));
            if (ok) break;
            assertEq(_state(seq), S.PENDING, "never spent by starving it");
        }
        admin.execute(seq);
        assertEq(_state(seq), S.EXECUTED);
    }

    // =============================================================================================== kind 5 ==

    function test_kind5_registersVoucher() public {
        GnoVoucher v = new GnoVoucher("Foo", "FOO", 6, address(ics20), "transfer/client-0/ufoo");
        uint64 seq = _decidePending(S.KIND_VOUCHER, P.voucher(clientId, "ufoo", address(v), address(v).codehash));
        _executeAfterWeek(seq);
        assertEq(_state(seq), S.EXECUTED);
        assertEq(ics20.ibcERC20Contract("transfer/client-0/ufoo"), address(v));
    }

    function test_kind5_checks() public {
        GnoVoucher v = new GnoVoucher("Foo", "FOO", 6, address(ics20), "transfer/client-0/ufoo");
        GnoVoucher foreign = new GnoVoucher("Foo", "FOO", 6, address(0xdead), "transfer/client-0/ufoo");
        uint64 wrongHash = _decidePending(S.KIND_VOUCHER, P.voucher(clientId, "ufoo", address(v), bytes32(uint256(1))));
        uint64 wrongIcs20 =
            _decidePending(S.KIND_VOUCHER, P.voucher(clientId, "ufoo", address(foreign), address(foreign).codehash));
        uint64 taken = _decidePending(S.KIND_VOUCHER, P.voucher(clientId, "ugnot", address(v), address(v).codehash));
        address later = makeAddr("not deployed yet");
        uint64 pendingCode = _decidePending(S.KIND_VOUCHER, P.voucher(clientId, "ubar", later, address(v).codehash));
        _skip(7 days);
        admin.execute(wrongHash);
        admin.execute(wrongIcs20);
        admin.execute(taken);
        assertEq(_state(wrongHash), S.SPENT);
        assertEq(_state(wrongIcs20), S.SPENT);
        assertEq(_state(taken), S.SPENT);
        // no code at the address: a failed check, spent for good (never retried once code appears)
        admin.execute(pendingCode);
        assertEq(_state(pendingCode), S.SPENT);
        vm.etch(later, address(v).code);
        vm.expectRevert(abi.encodeWithSelector(IIBCAdmin.NotPending.selector, pendingCode));
        admin.execute(pendingCode);
    }

    // =============================================================================================== kind 6 ==

    function test_kind6_addAndMigrateClients() public {
        MockLightClient lc2 = new MockLightClient();
        uint64 add = _decidePending(
            S.KIND_CLIENT, P.client(1, "gnoland-2", "ethereum-2", _prefix(), address(lc2), address(lc2).codehash)
        );
        MockLightClient lc3 = new MockLightClient();
        uint64 migrate =
            _decidePending(S.KIND_CLIENT, P.client(2, clientId, CP, _prefix(), address(lc3), address(lc3).codehash));
        uint64 badId = _decidePending(
            S.KIND_CLIENT, P.client(1, "client-77", "ethereum-2", _prefix(), address(lc2), address(lc2).codehash)
        );
        _skip(7 days);
        admin.execute(add);
        admin.execute(migrate);
        admin.execute(badId);
        assertEq(address(router.getClient("gnoland-2")), address(lc2));
        assertEq(router.getCounterparty("gnoland-2").clientId, "ethereum-2");
        assertEq(address(router.getClient(clientId)), address(lc3));
        assertEq(_state(badId), S.SPENT);
    }

    // =============================================================================================== kind 7 ==

    function test_kind7_upgradesTheTransferApp() public {
        address impl = address(
            new GnoICS20Transfer(
                address(new GnoICS20Controls(address(new GnoICS20Reconcile(address(new GnoICS20Evidence())))))
            )
        );
        uint64 seq = _decidePending(S.KIND_UPGRADE, P.upgrade(address(ics20), impl, impl.codehash, ""));
        _executeAfterWeek(seq);
        assertEq(_state(seq), S.EXECUTED);
        assertEq(
            address(
                uint160(
                    uint256(vm.load(address(ics20), 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc))
                )
            ),
            impl
        );
        assertTrue(_isSuccessAck(_gnotIn(1, bob)), "the controls' state survived");
    }

    function test_kind7_upgradesTheRouter_andABeacon() public {
        address routerImpl = address(new ICS26Router());
        address escrowImpl = address(new Escrow());
        uint64 a = _decidePending(S.KIND_UPGRADE, P.upgrade(address(router), routerImpl, routerImpl.codehash, ""));
        address beacon = IICS20Transfer(address(ics20)).getEscrowBeacon();
        uint64 b = _decidePending(S.KIND_UPGRADE, P.upgrade(beacon, escrowImpl, escrowImpl.codehash, ""));
        _skip(7 days);
        admin.execute(a);
        admin.execute(b);
        assertEq(_state(a), S.EXECUTED);
        assertEq(_state(b), S.EXECUTED);
        assertEq(UpgradeableBeacon(beacon).implementation(), escrowImpl);
    }

    function test_kind7_checks() public {
        address impl = address(
            new GnoICS20Transfer(
                address(new GnoICS20Controls(address(new GnoICS20Reconcile(address(new GnoICS20Evidence())))))
            )
        );
        uint64 notAProxy = _decidePending(S.KIND_UPGRADE, P.upgrade(address(usdc), impl, impl.codehash, ""));
        uint64 wrongHash = _decidePending(S.KIND_UPGRADE, P.upgrade(address(ics20), impl, bytes32(uint256(7)), ""));
        // a call that reverts (re-running the one-time initializer): the upgrade rolls back whole and is spent
        uint64 reverting = _decidePending(
            S.KIND_UPGRADE,
            P.upgrade(
                address(ics20),
                impl,
                impl.codehash,
                abi.encodeWithSignature("initializeGno(address[6])", G[0], G[1], G[2], G[3], W[0], W[1])
            )
        );
        _skip(7 days);
        admin.execute(notAProxy);
        admin.execute(wrongHash);
        assertEq(_state(notAProxy), S.SPENT);
        assertEq(_state(wrongHash), S.SPENT);
        bytes32 implSlot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        bytes32 before = vm.load(address(ics20), implSlot);
        admin.execute(reverting);
        assertEq(_state(reverting), S.SPENT);
        assertEq(vm.load(address(ics20), implSlot), before, "rolled back");
    }

    function test_kind7_nestedUpgradeRefused() public {
        address a = address(
            new GnoICS20Transfer(
                address(new GnoICS20Controls(address(new GnoICS20Reconcile(address(new GnoICS20Evidence())))))
            )
        );
        address b = address(
            new GnoICS20Transfer(
                address(new GnoICS20Controls(address(new GnoICS20Reconcile(address(new GnoICS20Evidence())))))
            )
        );
        bytes memory nested = abi.encodeWithSignature("upgradeToAndCall(address,bytes)", b, "");
        bytes[] memory calls = new bytes[](1);
        calls[0] = nested;
        uint64 direct = _decidePending(S.KIND_UPGRADE, P.upgrade(address(ics20), a, a.codehash, nested));
        uint64 viaMulticall = _decidePending(
            S.KIND_UPGRADE,
            P.upgrade(address(ics20), a, a.codehash, abi.encodeWithSignature("multicall(bytes[])", calls))
        );
        bytes32 implSlot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        bytes32 before = vm.load(address(ics20), implSlot);
        _skip(7 days);
        admin.execute(direct);
        admin.execute(viaMulticall);
        assertEq(_state(direct), S.SPENT);
        assertEq(_state(viaMulticall), S.SPENT);
        assertEq(vm.load(address(ics20), implSlot), before, "neither A nor B installed");
    }

    // =============================================================================================== kind 8 ==

    function test_kind8_relayerRole_grantWaits_revokeAtRecording() public {
        IAccessManager am = IAccessManager(d.accessManager);
        uint64 grant = _decidePending(S.KIND_ROLE, P.role(true, IBCRolesLib.RELAYER_ROLE, alice));
        _executeAfterWeek(grant);
        (bool has,) = am.hasRole(IBCRolesLib.RELAYER_ROLE, alice);
        assertTrue(has);
        (uint64 seq, uint8 status) = _decide(S.KIND_ROLE, P.role(false, IBCRolesLib.RELAYER_ROLE, alice));
        assertEq(status, S.STATUS_RECORDED);
        assertEq(_state(seq), S.EXECUTED);
        (has,) = am.hasRole(IBCRolesLib.RELAYER_ROLE, alice);
        assertFalse(has);
    }

    function test_kind8_onlyTheRelayerRole() public {
        uint64[5] memory refused = [
            IBCRolesLib.ADMIN_ROLE,
            IBCRolesLib.PAUSER_ROLE,
            IBCRolesLib.ID_CUSTOMIZER_ROLE,
            IBCRolesLib.ERC20_CUSTOMIZER_ROLE,
            IBCRolesLib.DELEGATE_SENDER_ROLE
        ];
        for (uint256 i = 0; i < refused.length; i++) {
            (, uint8 status) = _decide(S.KIND_ROLE, P.role(true, refused[i], alice));
            assertEq(status, S.STATUS_SPENT);
            (, status) = _decide(S.KIND_ROLE, P.role(false, refused[i], address(admin)));
            assertEq(status, S.STATUS_SPENT);
        }
    }

    // =============================================================================================== kind 9 ==

    function test_kind9_handOver_swapsTheExecutor() public {
        IBCAdminExec next = new IBCAdminExec(address(router), d.accessManager, address(ics20));
        uint64 seq = _decidePending(
            S.KIND_HANDOVER,
            P.handover(address(next), address(next).codehash, abi.encodeCall(IBCAdminExec.bindings, ()))
        );
        _executeAfterWeek(seq);
        (address x, bytes32 h) = admin.exec();
        assertEq(x, address(next));
        assertEq(h, address(next).codehash);
        // decisions now run in the new executor; state and authority stayed in IBCAdmin
        uint64 after_ = _decidePending(S.KIND_SETTINGS, P.settings(clientId, 2 days));
        _executeAfterWeek(after_);
        assertEq(ctl.quarantineSeconds(clientId), 2 days);
    }

    function test_kind9_refusesAnExecutorBoundElsewhere() public {
        IBCAdminExec foreign = new IBCAdminExec(address(router), d.accessManager, address(usdc));
        uint64 seq = _decidePending(S.KIND_HANDOVER, P.handover(address(foreign), address(foreign).codehash, ""));
        _executeAfterWeek(seq);
        assertEq(_state(seq), S.SPENT);
        (address x,) = admin.exec();
        assertEq(x, d.ibcAdminExec);
    }

    function test_executorCodeIsPinned() public {
        uint64 seq = _decidePending(S.KIND_SETTINGS, P.settings(clientId, 1 days));
        vm.etch(d.ibcAdminExec, address(new MockLightClient()).code);
        _skip(7 days);
        vm.expectRevert(IIBCAdmin.ForeignExec.selector);
        admin.execute(seq);
    }

    // ============================================================================================== kind 10 ==

    function test_kind10_routeReplacement_opensTheNextEpoch() public {
        _setLimits(address(usdc), 1000, 1000, 1000);
        IICS26RouterMsgs.Packet memory out = _send(alice, address(usdc), 100, clientId);
        MockLightClient lc2 = new MockLightClient();
        uint64 add = _decidePending(
            S.KIND_CLIENT, P.client(1, "gnoland-2", "ethereum-2", _prefix(), address(lc2), address(lc2).codehash)
        );
        uint64 stale = _decidePending(S.KIND_SETTINGS, P.settings(clientId, 1 days));
        uint64 replace = _decidePending(S.KIND_ROUTE, P.route(clientId, "gnoland-2"));
        _skip(7 days);
        admin.execute(add);
        admin.execute(replace);

        assertEq(admin.epoch(), 2);
        assertEq(admin.govClient(), "gnoland-2");
        assertEq(admin.lastSeq(), 0);
        IBCAdminExec x = IBCAdminExec(d.ibcAdminExec);
        assertEq(address(router.getClient(clientId)), x.frozenClient());
        assertEq(ctl.routeKey("gnoland-2"), clientId);
        assertTrue(ctl.isRetired(clientId));
        assertEq(ics20.getEscrow("gnoland-2"), ics20.getEscrow(clientId));

        // the old epoch's unexecuted decision is dropped
        vm.expectRevert(abi.encodeWithSelector(IIBCAdmin.NotPending.selector, stale));
        admin.execute(stale);

        // the new epoch takes packets over the new client from 1; the old epoch is stale
        assertEq(_status(_recvGov(_env(1, S.KIND_SETTINGS, P.settings(clientId, 2 days)))), S.STATUS_RECORDED);
        assertTrue(_isErrorAck(_recvGov(_envelope(1, 2, S.KIND_SETTINGS, P.settings(clientId, 2 days)))));
        // nothing goes through the frozen client any more
        IICS26RouterMsgs.Packet memory old =
            _packetFromGno(clientId, "transfer", "ics20-1", "application/x-solidity-abi", "");
        vm.expectRevert();
        router.recvPacket(IICS26RouterMsgs.MsgRecvPacket(old, "", IICS02ClientMsgs.Height(0, 1)));
        // the route stays closed until reconciled and reopened by decision (kinds 12, 13)
        assertTrue(ctl.routeClosed("gnoland-2"));
        assertTrue(_isErrorAck(_transferIn("gnoland-2", "ugnot", 5, bob)));
        // the packet in flight on the old id is still open: reopening is spent until it is reconciled
        uint64 early = _decidePending(S.KIND_REOPEN, P.reopen("gnoland-2"));
        _executeAfterWeek(early);
        assertEq(_state(early), S.SPENT);
        _proveDelivered(out);
        uint64 settle = _decidePending(S.KIND_SETTLE, P.settle1(clientId, out.sequence, 3, 0));
        uint64 reopen = _decidePending(S.KIND_REOPEN, P.reopen("gnoland-2"));
        _skip(7 days);
        admin.execute(settle);
        admin.execute(reopen);
        assertEq(_state(reopen), S.EXECUTED);
        assertTrue(_isSuccessAck(_transferIn("gnoland-2", "ugnot", 5, bob)));
    }

    function test_kind10_checks() public {
        uint64 notGov = _decidePending(S.KIND_ROUTE, P.route("other-1", "gnoland-2"));
        uint64 unknownNew = _decidePending(S.KIND_ROUTE, P.route(clientId, "gnoland-404"));
        _skip(7 days);
        admin.execute(notGov);
        admin.execute(unknownNew);
        assertEq(_state(notGov), S.SPENT);
        assertEq(_state(unknownNew), S.SPENT);
        assertEq(admin.epoch(), 1);
    }

    // ============================================================================================== kind 11 ==

    function test_kind11_lengtheningAtRecording_shorteningWaits() public {
        (uint64 seq, uint8 status) = _decide(S.KIND_SETTINGS, P.settings(clientId, 14 days));
        assertEq(status, S.STATUS_RECORDED);
        assertEq(_state(seq), S.EXECUTED);
        assertEq(ctl.quarantineSeconds(clientId), 14 days);
        uint64 shorten = _decidePending(S.KIND_SETTINGS, P.settings(clientId, 0));
        _executeAfterWeek(shorten);
        assertEq(ctl.quarantineSeconds(clientId), 0);
        (, status) = _decide(S.KIND_SETTINGS, P.settings(clientId, 400 days));
        assertEq(status, S.STATUS_SPENT);
    }

    // ============================================================================================ execution ==

    function test_execute_onlyPendingOnce() public {
        vm.expectRevert(abi.encodeWithSelector(IIBCAdmin.NotPending.selector, 1));
        admin.execute(1);
        uint64 seq = _decidePending(S.KIND_SETTINGS, P.settings(clientId, 1 days));
        _executeAfterWeek(seq);
        vm.expectRevert(abi.encodeWithSelector(IIBCAdmin.NotPending.selector, seq));
        admin.execute(seq);
    }

    // ================================================================================================ setup ==

    function test_finishSetup_once() public {
        vm.expectRevert(IIBCAdmin.SetupAlreadyDone.selector);
        vm.prank(deployer);
        admin.finishSetup(launch);
    }

    function test_setupCheck_findsLeftovers() public {
        IBCAdminSetupCheck check = IBCAdminSetupCheck(IBCAdminExec(d.ibcAdminExec).setupCheck());
        check.check(address(admin), deployer);
        IAccessManager am = IAccessManager(d.accessManager);

        vm.prank(address(admin));
        am.grantRole(IBCRolesLib.PAUSER_ROLE, deployer, 0);
        vm.expectRevert(abi.encodeWithSelector(IIBCAdmin.SetupIncomplete.selector, 2));
        check.check(address(admin), deployer);
        vm.prank(address(admin));
        am.revokeRole(IBCRolesLib.PAUSER_ROLE, deployer);

        bytes4[] memory sel = new bytes4[](1);
        sel[0] = IGnoICS20Controls.setLimits.selector;
        vm.prank(address(admin));
        am.setTargetFunctionRole(address(ics20), sel, 42);
        vm.expectRevert(abi.encodeWithSelector(IIBCAdmin.SetupIncomplete.selector, 6));
        check.check(address(admin), deployer);
        vm.prank(address(admin));
        am.setTargetFunctionRole(address(ics20), sel, IBCRolesLib.ADMIN_ROLE);

        vm.prank(address(admin));
        am.setTargetClosed(address(router), true);
        vm.expectRevert(abi.encodeWithSelector(IIBCAdmin.SetupIncomplete.selector, 4));
        check.check(address(admin), deployer);
    }

    // ============================================================================================= round 13 ==

    /// @notice r13 #1: kind 5's denom grammar is the one shared with gno.land's ibcgov builder (`isGnoWireDenom`):
    /// a native `[a-z][a-z0-9]{2,15}`, or `gno.land:r` and at least two Re_name segments
    /// `[a-z][a-z0-9]*([_-][a-z0-9]+)*` with an optional `.` slug of 1 to 32 `[A-Za-z0-9_-]`, at most 128 bytes. Cases
    /// mirror the gno side's.
    function test_r13_1_kind5_gnoDenomGrammar() public pure {
        string[14] memory good = [
            // gno-realms' TestGRC20AliasRoundTrip
            "gno.land:r:demo:foo",
            "gno.land:r:demo:foo.FOO",
            "gno.land:r:demo:foo.Bar123",
            // hyphenated and underscored paths, version segments
            "gno.land:r:my-org:token.TKN",
            "gno.land:r:my-org:token.TOK",
            "gno.land:r:my_org:my-token_v2.TKN",
            "gno.land:r:nt:grc20:v0.TKN",
            "gno.land:r:a1-b2_c3:d4.T",
            "gno.land:r:demo:foo.A-b_9",
            "gno.land:r:demo:foo.ABCDEFGHIJKLMNOPQRSTUVWXYZ012345", // a 32-byte slug
            // native
            "ugnot",
            "abc",
            "abcdefghijklmnop",
            "a1b2"
        ];
        for (uint256 i = 0; i < good.length; i++) {
            assertTrue(S.canonicalGnoDenom(good[i]), good[i]);
        }
        string[22] memory bad = [
            "gno.land:r:my--org:token.TKN", // doubled separator
            "gno.land:r:my_:token.TKN", // trailing `_`
            "gno.land:r:my-:token.TKN", // trailing `-`
            "gno.land:r:-my:token.TKN", // leading separator
            "gno.land:r:my_-org:token.TKN",
            "gno.land:r:1org:token.TKN",
            "gno.land:r:demo.FOO", // one segment
            "gno.land:r:demo",
            "gno.land:r:demo:foo.ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456", // a 33-byte slug
            "gno.land:r:demo:foo.",
            "gno.land:r:demo:foo.T.U",
            "gno.land:r:demo#sub:foo.T",
            "gno.land:p:demo:foo.T",
            "gno.land:e:g1abc:run.T",
            "/gno.land/r/demo:foo", // a realm-issued coin
            "ibc/ABC123",
            "u_gnot",
            "abcdefghijklmnopq", // 17
            "Ugnot",
            "ug",
            "1gnot",
            "gno.land:r:demo:foo.FO O"
        ];
        for (uint256 i = 0; i < bad.length; i++) {
            assertFalse(S.canonicalGnoDenom(bad[i]), bad[i]);
        }
        // at most 128 bytes in all
        bytes memory long = bytes("gno.land:r:demo:");
        while (long.length < 128) long = bytes.concat(long, "a");
        assertEq(bytes(long).length, 128);
        assertTrue(S.canonicalGnoDenom(string(long)));
        assertFalse(S.canonicalGnoDenom(string.concat(string(long), "a")));
    }

    /// @notice r13 #1, across the chains: kind 5 registers `gno.land:r:my-org:token.TKN`'s voucher, and a transfer of
    /// that denom from gno.land mints it.
    function test_r13_1_hyphenatedGrc20_registeredAndReceived() public {
        string memory denom = "gno.land:r:my-org:token.TKN";
        GnoVoucher v =
            new GnoVoucher("Token", "TOK", 6, address(ics20), string.concat("transfer/", clientId, "/", denom));
        uint64 seq = _decidePending(S.KIND_VOUCHER, P.voucher(clientId, denom, address(v), address(v).codehash));
        _executeAfterWeek(seq);
        assertEq(_state(seq), S.EXECUTED);
        _setLimits(address(v), 1000, 1000, 1000);
        assertTrue(_isSuccessAck(_transferIn(clientId, denom, 25, bob)));
        assertEq(v.balanceOf(bob), 25);
    }

    // ============================================================================================= round 15 ==

    /// @notice `finishSetup`'s launch checks (run before the role check list), on a fresh IBCAdmin over this
    /// deployment (the fixture's is set up already).
    function _expectSetup(IIBCAdmin.Launch memory l, uint8 n) internal {
        IBCAdmin fresh = _freshAdmin();
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IIBCAdmin.SetupIncomplete.selector, n));
        fresh.finishSetup(l);
    }

    function _freshAdmin() internal returns (IBCAdmin fresh) {
        vm.startPrank(deployer);
        fresh = new IBCAdmin(
            IBCAdmin.Config({
                router: address(router),
                accessManager: d.accessManager,
                ics20: address(ics20),
                exec: d.ibcAdminExec,
                govClientId: clientId,
                gnoChainId: "gno-test",
                seats: G,
                watch: W,
                recovery: IIBCAdmin.RecoveryConfig(0, 0, 0, 0, 0)
            })
        );
        vm.stopPrank();
    }

    /// @notice r15 #1 (b): `finishSetup` checks the launch client and everything naming it against the deployment's
    /// record; each mismatch fails it with its own number.
    function test_r15_1_setupCheck_launchBindings() public {
        IIBCAdmin.Launch memory l = launch;
        l.clientId = "client-1";
        _expectSetup(l, 11);
        l = launch;
        l.lightClient = address(new MockLightClient());
        _expectSetup(l, 11);
        l = launch;
        l.lightClientCodeHash = bytes32(uint256(1));
        _expectSetup(l, 11);
        l = launch;
        l.clientStateHash = bytes32(uint256(1));
        _expectSetup(l, 12);
        lc.setChainId("other-chain");
        _expectSetup(launch, 12);
        lc.setChainId("gno-test");
        l = launch;
        l.counterpartyClientId = "ethereum-9";
        _expectSetup(l, 13);
        l = launch;
        l.ugnotVoucher = address(0x5555);
        _expectSetup(l, 14);
        l = launch;
        l.quarantineSeconds = 1 days;
        _expectSetup(l, 15);
        // only the deployer attests its launch
        vm.expectRevert(IIBCAdmin.SetupAlreadyDone.selector);
        admin.finishSetup(launch);
    }
}
