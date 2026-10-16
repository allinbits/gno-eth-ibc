// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Strings } from "@openzeppelin-contracts/utils/Strings.sol";
import { IAccessManager } from "@openzeppelin-contracts/access/manager/IAccessManager.sol";
import { IAccessManaged } from "@openzeppelin-contracts/access/manager/IAccessManaged.sol";

import { IICS26RouterMsgs } from "@eureka/msgs/IICS26RouterMsgs.sol";
import { IICS02ClientMsgs } from "@eureka/msgs/IICS02ClientMsgs.sol";
import { IICS20TransferMsgs } from "@eureka/msgs/IICS20TransferMsgs.sol";
import { IICS20Errors } from "@eureka/errors/IICS20Errors.sol";
import { ICS24Host } from "@eureka/utils/ICS24Host.sol";
import { IBCRolesLib } from "@eureka/utils/IBCRolesLib.sol";

import { GnoVoucher } from "../../src/GnoVoucher.sol";
import { IGnoICS20Controls, IGnoICS20ControlsTypes as T } from "../../src/interfaces/IGnoICS20Controls.sol";
import { IGuardians } from "../../src/interfaces/IGuardians.sol";
import { GnoTransferStorage } from "../../src/transfer/GnoTransferStorage.sol";
import { GnoICS20Controls } from "../../src/transfer/GnoICS20Controls.sol";
import { IBCAdminStorage } from "../../src/admin/IBCAdminStorage.sol";
import { MockLightClient } from "../utils/MockLightClient.sol";
import { RefusingToken } from "../utils/RefusingToken.sol";
import { ControlsFixture } from "./ControlsFixture.sol";

/// @notice GnoICS20Transfer's controls through the real router: E5 receive limits and default deny, E7 route flags
/// and the refunds hold, E9 quarantine, send limits and send records, the refund meter and its queue (§7.13), and
/// route keys (E12).
contract GnoICS20TransferTest is ControlsFixture {
    function _usdcLimits(uint256 maxPerMessage, uint256 dayCap, uint256 refundCap) internal {
        _setLimits(address(usdc), maxPerMessage, dayCap, refundCap);
    }

    function _usdcDenomFromGno() internal view returns (string memory) {
        return string.concat("transfer/", CP, "/", Strings.toHexString(address(usdc)));
    }

    // ================================================================================================ setup ==

    function test_setup_finishedAndHandedOver() public view {
        assertTrue(admin.setupDone());
        IAccessManager am = IAccessManager(d.accessManager);
        (bool isAdmin,) = am.hasRole(IBCRolesLib.ADMIN_ROLE, address(admin));
        assertTrue(isAdmin);
        (bool deployerAdmin,) = am.hasRole(IBCRolesLib.ADMIN_ROLE, deployer);
        assertFalse(deployerAdmin);
        assertEq(ics20.CONTROLS(), d.ics20Controls);
        address[6] memory k = ctl.guardianKeys();
        assertEq(k[0], G[0]);
        assertEq(k[5], W[1]);
        assertEq(ctl.quarantineSeconds(clientId), 7 days);
        assertEq(ctl.routeKey(clientId), clientId);
    }

    function test_storageSlots_areTheirNamespaces() public pure {
        assertEq(
            GnoTransferStorage.SLOT,
            keccak256(abi.encode(uint256(keccak256("gno.storage.GnoICS20Transfer")) - 1)) & ~bytes32(uint256(0xff))
        );
        assertEq(
            IBCAdminStorage.SLOT,
            keccak256(abi.encode(uint256(keccak256("gno.storage.IBCAdmin")) - 1)) & ~bytes32(uint256(0xff))
        );
    }

    function test_governance_restrictedToAdmin() public {
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, alice));
        vm.prank(alice);
        ctl.setLimits(clientId, address(usdc), T.Limits(1, 1, 1, 0, 0));
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, deployer));
        vm.prank(deployer);
        ctl.setQuarantine(clientId, 0);
        // the deployer cannot re-initialize or re-key the controls either
        vm.expectRevert();
        vm.prank(deployer);
        ctl.initializeGno([alice, bob, G[0], G[1], G[2], G[3]]);
    }

    function test_controls_refuseDirectCalls() public {
        vm.expectRevert(GnoICS20Controls.NotDelegated.selector);
        GnoICS20Controls(d.ics20Controls).routeKey(clientId);
    }

    function test_ackHook_onlyThroughTheForksOwnCall() public {
        bytes memory call = abi.encodeWithSignature(
            "ackHook(string,uint64,uint8,address,address,uint256,bytes)",
            clientId,
            uint64(1),
            uint8(T.Outcome.Timeout),
            address(usdc),
            alice,
            uint256(1),
            ""
        );
        (bool ok, bytes memory ret) = address(ics20).call(call);
        assertFalse(ok);
        assertEq(bytes4(ret), GnoICS20Controls.NotHook.selector);
    }

    function test_setLimits_refusesBadValues() public {
        vm.startPrank(address(admin));
        vm.expectRevert(T.GnoBadLimits.selector);
        ctl.setLimits(clientId, address(0), T.Limits(1, 1, 1, 0, 0));
        vm.expectRevert(T.GnoBadLimits.selector);
        ctl.setLimits(clientId, address(usdc), T.Limits(1, uint256(type(uint128).max) + 1, 1, 0, 0));
        vm.expectRevert(T.GnoBadLimits.selector);
        ctl.setLimits(clientId, address(usdc), T.Limits(1, 1, 1, 5, 6));
        vm.expectRevert(T.GnoBadLimits.selector);
        ctl.setQuarantine(clientId, 366 days);
        vm.stopPrank();
    }

    // ============================================================================================= receives ==

    function test_recv_gnot_mintsRegisteredVoucher() public {
        bytes memory ack = _gnotIn(1000e6, bob);
        assertTrue(_isSuccessAck(ack));
        assertEq(ugnot.balanceOf(bob), 1000e6);
        assertEq(ugnot.totalSupply(), 1000e6);
        assertEq(ctl.limits(clientId, address(ugnot)).receiveLevel, 1000e6);
    }

    function test_recv_overMaxPerMessage_errorAck() public {
        assertTrue(_isErrorAck(_gnotIn(GNOT_MAX + 1, bob)));
        assertEq(ugnot.totalSupply(), 0);
        assertEq(ctl.limits(clientId, address(ugnot)).receiveLevel, 0);
    }

    function test_recv_overDayCap_errorAck_thenRefills() public {
        for (uint256 i = 0; i < 4; i++) {
            assertTrue(_isSuccessAck(_gnotIn(GNOT_MAX, bob)));
        }
        assertTrue(_isErrorAck(_gnotIn(1, bob)), "day cap reached");
        _skip(6 hours); // a quarter of the cap drained
        assertTrue(_isSuccessAck(_gnotIn(GNOT_MAX, bob)));
        assertTrue(_isErrorAck(_gnotIn(1, bob)));
        _skip(1 days);
        assertTrue(_isSuccessAck(_gnotIn(GNOT_MAX, bob)));
        assertEq(ugnot.balanceOf(bob), 6 * GNOT_MAX);
    }

    function test_recv_unregisteredDenom_defaultDeny() public {
        assertTrue(_isErrorAck(_transferIn(clientId, "uatom", 1, bob)));
        vm.expectRevert(abi.encodeWithSelector(IICS20Errors.ICS20DenomNotFound.selector, "transfer/client-0/uatom"));
        ics20.ibcERC20Contract("transfer/client-0/uatom");
    }

    function test_recv_registeredWithoutLimits_refused() public {
        GnoVoucher foo = new GnoVoucher("Foo", "FOO", 6, address(ics20), "transfer/client-0/ufoo");
        vm.prank(address(admin));
        ics20.setCustomERC20("transfer/client-0/ufoo", address(foo));
        assertTrue(_isErrorAck(_transferIn(clientId, "ufoo", 1, bob)));
        _setLimits(address(foo), 10, 10, 10);
        assertTrue(_isSuccessAck(_transferIn(clientId, "ufoo", 10, bob)));
        assertEq(foo.balanceOf(bob), 10);
    }

    function test_recv_returningNative_releasesWithinLimits() public {
        _usdcLimits(500e6, 1000e6, 1000e6);
        IICS26RouterMsgs.Packet memory out = _send(alice, address(usdc), 800e6, clientId);
        assertEq(usdc.balanceOf(ics20.getEscrow(clientId)), 800e6);
        // outstanding, the send's escrow is reserved: its refund could still be owed
        assertTrue(_isErrorAck(_transferIn(clientId, _usdcDenomFromGno(), 1, bob)), "reserved");
        _ack(out, bytes("{\"result\":\"AQ==\"}"));
        assertTrue(_isErrorAck(_transferIn(clientId, _usdcDenomFromGno(), 501e6, bob)), "over max");
        assertTrue(_isSuccessAck(_transferIn(clientId, _usdcDenomFromGno(), 500e6, bob)));
        assertEq(usdc.balanceOf(bob), 500e6);
        _usdcLimits(0, 0, 0); // tightened: nothing more is released
        assertTrue(_isErrorAck(_transferIn(clientId, _usdcDenomFromGno(), 1, bob)));
    }

    function test_recv_routeFlag_pauses_untilCleared() public {
        vm.prank(W[0]);
        ctl.setRouteFlag(clientId);
        assertTrue(ctl.routePaused(clientId));
        assertTrue(_isErrorAck(_gnotIn(1, bob)));
        vm.prank(W[0]);
        ctl.clearRouteFlag(clientId);
        assertTrue(_isSuccessAck(_gnotIn(1, bob)));
    }

    function test_flags_onlyKeys() public {
        vm.expectRevert(IGuardians.UnknownKey.selector);
        vm.prank(alice);
        ctl.setRouteFlag(clientId);
        vm.expectRevert(IGuardians.UnknownKey.selector);
        vm.prank(alice);
        ctl.setRefundsFlag(clientId);
    }

    function test_recv_quarantine() public {
        lc.setTransitionTime(uint64(_now()));
        assertTrue(_isErrorAck(_gnotIn(1, bob)));
        _skip(7 days - 13);
        assertTrue(_isErrorAck(_gnotIn(1, bob)));
        _skip(13);
        assertTrue(_isSuccessAck(_gnotIn(1, bob)));
    }

    function test_recv_quarantineDisabled_forLaterTransitionsOnly() public {
        lc.setTransitionTime(uint64(_now()));
        _skip(1 days);
        vm.prank(address(admin));
        ctl.setQuarantine(clientId, 0);
        assertTrue(_isErrorAck(_gnotIn(1, bob)), "a started quarantine keeps its deadline");
        _skip(6 days);
        assertTrue(_isSuccessAck(_gnotIn(1, bob)));
        lc.setTransitionTime(uint64(_now())); // a transition after the change: not quarantined
        assertTrue(_isSuccessAck(_gnotIn(1, bob)));
    }

    function test_recv_recoveryBlock() public {
        vm.prank(address(admin));
        ctl.setRecoveryBlock(clientId, true);
        assertTrue(_isErrorAck(_gnotIn(1, bob)));
        vm.prank(address(admin));
        ctl.setRecoveryBlock(clientId, false);
        assertTrue(_isSuccessAck(_gnotIn(1, bob)));
    }

    // ================================================================================================ sends ==

    function test_send_native_requiresLimits() public {
        _sendExpectRevert(
            alice,
            address(usdc),
            1,
            clientId,
            abi.encodeWithSelector(T.GnoLimitsNotSet.selector, clientId, address(usdc))
        );
    }

    function test_send_native_minAndMax() public {
        _setLimits(clientId, address(usdc), T.Limits(0, 0, 0, 100, 10));
        _sendExpectRevert(
            alice, address(usdc), 9, clientId, abi.encodeWithSelector(T.GnoSendBelowMin.selector, address(usdc), 9, 10)
        );
        _sendExpectRevert(
            alice,
            address(usdc),
            101,
            clientId,
            abi.encodeWithSelector(T.GnoSendAboveMax.selector, address(usdc), 101, 100)
        );
        _send(alice, address(usdc), 100, clientId);
    }

    function test_send_native_pausedByFlag_voucherReturnNever() public {
        _usdcLimits(1e6, 1e6, 1e6);
        _gnotIn(5e6, alice);
        vm.prank(G[1]);
        ctl.setRouteFlag(clientId);
        _sendExpectRevert(
            alice, address(usdc), 1, clientId, abi.encodeWithSelector(T.GnoRoutePaused.selector, clientId)
        );
        // a voucher returning to gno.land is a burn: never paused or limited
        vm.prank(alice);
        ugnot.approve(address(ics20), type(uint256).max);
        IICS26RouterMsgs.Packet memory pkt = _send(alice, address(ugnot), 5e6, clientId);
        assertEq(ugnot.totalSupply(), 0);
        T.SendRecord memory rec = ctl.sendRecord(clientId, pkt.sequence);
        assertTrue(rec.burned);
    }

    function test_send_writesRecord() public {
        _usdcLimits(1e6, 1e6, 1e6);
        IICS26RouterMsgs.Packet memory pkt = _send(alice, address(usdc), 7, clientId);
        T.SendRecord memory rec = ctl.sendRecord(clientId, pkt.sequence);
        assertEq(rec.commitment, ICS24Host.packetCommitmentBytes32(pkt));
        assertEq(rec.commitment, router.getCommitment(ICS24Host.packetCommitmentKeyCalldata(clientId, pkt.sequence)));
        assertEq(rec.sender, alice);
        assertEq(rec.token, address(usdc));
        assertEq(rec.amount, 7);
        assertEq(rec.timeoutTimestamp, pkt.timeoutTimestamp);
        assertEq(rec.sendBlock, vm.getBlockNumber());
        assertEq(rec.escrow, ics20.getEscrow(clientId));
        assertFalse(rec.burned);
        assertEq(uint8(rec.outcome), uint8(T.Outcome.Pending));
    }

    // ============================================================================================== refunds ==

    function test_successAck_attachesOutcome() public {
        _usdcLimits(1e6, 1e6, 1e6);
        IICS26RouterMsgs.Packet memory pkt = _send(alice, address(usdc), 7, clientId);
        _skip(60);
        _ack(pkt, bytes("{\"result\":\"AQ==\"}"));
        T.SendRecord memory rec = ctl.sendRecord(clientId, pkt.sequence);
        assertEq(uint8(rec.outcome), uint8(T.Outcome.Success));
        assertEq(uint8(rec.payment), uint8(T.Payment.None));
        assertEq(rec.processedBlock, vm.getBlockNumber());
        assertEq(usdc.balanceOf(alice), 1_000_000e6 - 7);
    }

    function test_errorAck_refundsAtOnce() public {
        _usdcLimits(1e6, 1e6, 1e6);
        IICS26RouterMsgs.Packet memory pkt = _send(alice, address(usdc), 7, clientId);
        _errorAck(pkt);
        assertEq(usdc.balanceOf(alice), 1_000_000e6);
        T.SendRecord memory rec = ctl.sendRecord(clientId, pkt.sequence);
        assertEq(uint8(rec.outcome), uint8(T.Outcome.ErrorAck));
        assertEq(uint8(rec.payment), uint8(T.Payment.Paid));
        assertEq(rec.refunded, 7);
        assertEq(ctl.limits(clientId, address(usdc)).refundLevel, 7);
    }

    function test_timeout_refundsAtOnce() public {
        _usdcLimits(1e6, 1e6, 1e6);
        IICS26RouterMsgs.Packet memory pkt = _send(alice, address(usdc), 7, clientId);
        _timeout(pkt);
        assertEq(usdc.balanceOf(alice), 1_000_000e6);
        assertEq(uint8(ctl.sendRecord(clientId, pkt.sequence).outcome), uint8(T.Outcome.Timeout));
    }

    function test_voucherRefund_remintsReturnedVoucher() public {
        _gnotIn(5e6, alice);
        vm.prank(alice);
        ugnot.approve(address(ics20), type(uint256).max);
        IICS26RouterMsgs.Packet memory pkt = _send(alice, address(ugnot), 5e6, clientId);
        assertEq(ugnot.totalSupply(), 0);
        _errorAck(pkt);
        assertEq(ugnot.balanceOf(alice), 5e6);
        assertEq(ugnot.totalSupply(), 5e6);
    }

    function test_refundMeter_queuesBeyondCap_claimPaysAsItRefills() public {
        _usdcLimits(1000, 1000, 100);
        IICS26RouterMsgs.Packet memory p1 = _send(alice, address(usdc), 80, clientId);
        IICS26RouterMsgs.Packet memory p2 = _send(alice, address(usdc), 60, clientId);
        IICS26RouterMsgs.Packet memory p3 = _send(alice, address(usdc), 10, clientId);
        uint256 before = usdc.balanceOf(alice);
        _errorAck(p1); // paid at once
        _errorAck(p2); // 60 > 100 - 80: queued
        _errorAck(p3); // would fit, but queues behind p2
        assertEq(usdc.balanceOf(alice), before + 80);
        assertEq(uint8(ctl.sendRecord(clientId, p2.sequence).payment), uint8(T.Payment.Queued));
        assertEq(uint8(ctl.sendRecord(clientId, p3.sequence).payment), uint8(T.Payment.Queued));
        (uint64 head, uint64 tail) = ctl.refundQueue(clientId, address(usdc));
        assertEq(tail - head, 2);

        // 20 left in the bucket: an installment of p2
        assertEq(ctl.claim(clientId, address(usdc), 10), 0);
        assertEq(ctl.sendRecord(clientId, p2.sequence).refunded, 20);
        assertEq(usdc.balanceOf(alice), before + 100);

        _skip(1 days);
        assertEq(ctl.claim(clientId, address(usdc), 10), 2);
        assertEq(usdc.balanceOf(alice), before + 150);
        assertEq(uint8(ctl.sendRecord(clientId, p2.sequence).payment), uint8(T.Payment.Claimed));
        assertEq(uint8(ctl.sendRecord(clientId, p3.sequence).payment), uint8(T.Payment.Claimed));
        (head, tail) = ctl.refundQueue(clientId, address(usdc));
        assertEq(head, tail);
    }

    function test_refundsHold_queues_andBlocksClaim() public {
        _usdcLimits(1000, 1000, 1000);
        IICS26RouterMsgs.Packet memory pkt = _send(alice, address(usdc), 50, clientId);
        vm.prank(W[1]); // a watch key sets the refunds hold on an integrity break
        ctl.setRefundsFlag(clientId);
        assertTrue(ctl.refundsHeld(clientId));
        uint256 before = usdc.balanceOf(alice);
        _errorAck(pkt); // never refused: delayed
        assertEq(usdc.balanceOf(alice), before);
        assertEq(uint8(ctl.sendRecord(clientId, pkt.sequence).payment), uint8(T.Payment.Queued));
        vm.expectRevert(abi.encodeWithSelector(T.GnoRefundsHeld.selector, clientId));
        ctl.claim(clientId, address(usdc), 1);
        // receives are not touched by the refunds hold
        assertTrue(_isSuccessAck(_gnotIn(1, bob)));
        vm.prank(W[1]);
        ctl.clearRefundsFlag(clientId);
        assertEq(ctl.claim(clientId, address(usdc), 1), 1);
        assertEq(usdc.balanceOf(alice), before + 50);
    }

    function test_routeFlag_neverBlocksAcksOrRefunds() public {
        _usdcLimits(1000, 1000, 1000);
        IICS26RouterMsgs.Packet memory pkt = _send(alice, address(usdc), 50, clientId);
        vm.prank(G[0]);
        ctl.setRouteFlag(clientId);
        vm.prank(G[1]);
        ctl.setRouteFlag(clientId); // a hold on the route
        _timeout(pkt);
        assertEq(usdc.balanceOf(alice), 1_000_000e6);
    }

    function test_unpauseRoute_clearsEarlierFlags_refusedUnderHold() public {
        vm.prank(G[0]);
        ctl.setRouteFlag(clientId);
        vm.prank(W[0]);
        ctl.setRefundsFlag(clientId);
        uint64 before = uint64(vm.getBlockNumber()) + 1;
        _skip(12);
        vm.prank(address(admin));
        assertEq(ctl.unpauseRoute(clientId, before), 2);
        assertFalse(ctl.routePaused(clientId));
        assertFalse(ctl.refundsHeld(clientId));
        vm.prank(G[0]);
        ctl.setRouteFlag(clientId);
        vm.prank(G[2]);
        ctl.setRouteFlag(clientId);
        vm.prank(address(admin));
        vm.expectRevert(IGuardians.HoldStands.selector);
        ctl.unpauseRoute(clientId, uint64(vm.getBlockNumber()) + 1);
    }

    function test_refundsHold_followsTheHoldRules() public {
        vm.prank(G[0]);
        ctl.setRefundsFlag(clientId);
        vm.prank(G[1]);
        ctl.setRefundsFlag(clientId); // two guardian refunds flags: a hold
        assertTrue(ctl.refundsHold(clientId).blockNumber != 0);
        _skip(12);
        vm.prank(address(admin));
        vm.expectRevert(IGuardians.HoldStands.selector);
        ctl.unpauseRoute(clientId, uint64(vm.getBlockNumber()));
        // one guardian lifts its own flag: 24 hours later the hold has ended and an unpause clears the rest
        vm.prank(G[1]);
        ctl.clearRefundsFlag(clientId);
        _skip(1 days);
        vm.prank(address(admin));
        assertEq(ctl.unpauseRoute(clientId, uint64(vm.getBlockNumber())), 1);
        assertFalse(ctl.refundsHeld(clientId));
    }

    function _refusing() internal returns (RefusingToken r) {
        r = new RefusingToken();
        r.mint(alice, 1000);
        r.mint(bob, 1000);
        vm.prank(alice);
        r.approve(address(ics20), type(uint256).max);
        vm.prank(bob);
        r.approve(address(ics20), type(uint256).max);
        _setLimits(address(r), 1000, 1000, 1000);
    }

    function test_refusedRefund_parked_neverBlocksTheAckOrOthers() public {
        RefusingToken r = _refusing();
        IICS26RouterMsgs.Packet memory pa = _send(alice, address(r), 100, clientId);
        IICS26RouterMsgs.Packet memory pb = _send(bob, address(r), 100, clientId);
        r.setBlocked(alice, true);
        _errorAck(pa); // the token refuses alice: the ack still goes through, the refund is parked
        assertEq(uint8(ctl.sendRecord(clientId, pa.sequence).payment), uint8(T.Payment.Parked));
        _errorAck(pb);
        assertEq(r.balanceOf(bob), 1000);
        vm.expectRevert(abi.encodeWithSelector(T.GnoRefundFailed.selector, clientId, pa.sequence));
        ctl.claimParked(clientId, pa.sequence);
        r.setBlocked(alice, false);
        assertEq(ctl.claimParked(clientId, pa.sequence), 100);
        assertEq(r.balanceOf(alice), 1000);
        assertEq(uint8(ctl.sendRecord(clientId, pa.sequence).payment), uint8(T.Payment.Claimed));
        vm.expectRevert(abi.encodeWithSelector(T.GnoNotParked.selector, clientId, pa.sequence));
        ctl.claimParked(clientId, pa.sequence);
    }

    function test_refusedQueuedRefund_parked_queueMovesOn() public {
        RefusingToken r = _refusing();
        _setLimits(address(r), 1000, 1000, 100);
        IICS26RouterMsgs.Packet memory p0 = _send(bob, address(r), 100, clientId);
        IICS26RouterMsgs.Packet memory pa = _send(alice, address(r), 100, clientId);
        IICS26RouterMsgs.Packet memory pb = _send(bob, address(r), 100, clientId);
        _errorAck(p0); // fills the meter
        _errorAck(pa); // queued
        _errorAck(pb); // queued behind alice
        r.setBlocked(alice, true);
        _skip(20 days);
        assertEq(ctl.claim(clientId, address(r), 5), 2);
        assertEq(uint8(ctl.sendRecord(clientId, pa.sequence).payment), uint8(T.Payment.Parked));
        assertEq(r.balanceOf(bob), 1000);
    }

    function test_burnedVoucherRefund_parked_undoesTheMint() public {
        _gnotIn(5e6, alice);
        vm.prank(alice);
        ugnot.approve(address(ics20), type(uint256).max);
        IICS26RouterMsgs.Packet memory pkt = _send(alice, address(ugnot), 5e6, clientId);
        // an escrow that refuses to pay: the voucher's re-mint is undone, the refund parked
        vm.mockCallRevert(
            ics20.getEscrow(clientId), abi.encodeWithSelector(bytes4(keccak256("send(address,address,uint256)"))), "no"
        );
        _errorAck(pkt);
        assertEq(ugnot.totalSupply(), 0);
        assertEq(uint8(ctl.sendRecord(clientId, pkt.sequence).payment), uint8(T.Payment.Parked));
        vm.clearMockedCalls();
        ctl.claimParked(clientId, pkt.sequence);
        assertEq(ugnot.balanceOf(alice), 5e6);
    }

    function test_replacedKeys_leaveNoStaleRouteHold() public {
        vm.prank(G[0]);
        ctl.setRouteFlag(clientId);
        vm.prank(G[1]);
        ctl.setRouteFlag(clientId);
        assertTrue(ctl.routeHold(clientId).blockNumber != 0);
        address[6] memory keys = [G[0], makeAddr("fresh"), G[2], G[3], W[0], W[1]];
        vm.prank(address(admin));
        ctl.setGuardianKeys(keys); // G[1]'s flag retires with its key
        assertEq(ctl.routeHold(clientId).blockNumber, 0);
        // the next flag on the route finds the stale hold and ends it: no 24-hour dip with the old start
        vm.prank(W[0]);
        ctl.setRouteFlag(clientId);
        assertEq(ctl.routeHold(clientId).blockNumber, 0);
        _skip(12);
        vm.prank(address(admin));
        ctl.unpauseRoute(clientId, uint64(vm.getBlockNumber()));
        assertFalse(ctl.routePaused(clientId));
    }

    /// @notice The refund meter never pays more than the bucket allows (cap + cap*t/day over t), and everything
    /// queued is paid in full once time and claims let it, in order.
    function testFuzz_refundMeter(uint256 seed) public {
        uint256 cap = 1000;
        _usdcLimits(type(uint128).max, type(uint128).max, cap);
        uint256 n = 6;
        IICS26RouterMsgs.Packet[] memory pkts = new IICS26RouterMsgs.Packet[](n);
        uint256 total;
        for (uint256 i = 0; i < n; i++) {
            uint256 amount = 1 + uint256(keccak256(abi.encode(seed, i))) % (2 * cap);
            pkts[i] = _send(alice, address(usdc), amount, clientId);
            total += amount;
        }
        uint256 start = _now();
        uint256 before = usdc.balanceOf(alice);
        for (uint256 i = 0; i < n; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, "step", i)));
            _skip(r % 6 hours);
            if (r % 2 == 0) _errorAck(pkts[i]);
            else _timeout(pkts[i]);
            if ((r >> 8) % 2 == 0) ctl.claim(clientId, address(usdc), 20);
            uint256 paid = usdc.balanceOf(alice) - before;
            assertLe(paid, cap + cap * (_now() - start) / 1 days, "refund bound");
        }
        for (uint256 i = 0; i < 20; i++) {
            _skip(1 days);
            ctl.claim(clientId, address(usdc), 20);
        }
        assertEq(usdc.balanceOf(alice) - before, total, "every refund paid in full");
        assertEq(ctl.reserved(clientId, address(usdc)), 0, "nothing owed, nothing reserved");
        for (uint256 i = 0; i < n; i++) {
            T.SendRecord memory rec = ctl.sendRecord(clientId, pkts[i].sequence);
            assertEq(rec.refunded, rec.amount);
        }
    }

    /// @notice Within any 24 hours of receives, at most two day caps are minted, each message at most the maximum.
    function testFuzz_receiveLimits(uint256 seed) public {
        uint256 start = _now();
        uint256 minted;
        for (uint256 i = 0; i < 25; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            _skip(r % 2 hours);
            if (_now() >= start + 1 days) break;
            uint256 amount = 1 + (r >> 16) % (GNOT_MAX + GNOT_MAX / 4);
            bytes memory ack = _gnotIn(amount, bob);
            if (_isSuccessAck(ack)) {
                assertLe(amount, GNOT_MAX);
                minted += amount;
            }
        }
        assertLe(minted, 2 * GNOT_DAY);
        assertEq(ugnot.totalSupply(), minted);
    }

    // =========================================================================================== route keys ==

    function _addClient(string memory id, address lightClient) internal {
        bytes[] memory prefix = new bytes[](2);
        prefix[0] = GNO_STORE;
        prefix[1] = GNO_KEY_PREFIX;
        vm.prank(address(admin));
        router.addClient(id, IICS02ClientMsgs.CounterpartyInfo("ethereum-2", prefix), lightClient);
    }

    function test_migrateRoute_movesEverythingInConstantWork() public {
        _usdcLimits(1000, 1000, 1000);
        IICS26RouterMsgs.Packet memory out = _send(alice, address(usdc), 300, clientId);
        _gnotIn(50, bob);
        address escrow = ics20.getEscrow(clientId);
        _addClient("gnoland-9", address(new MockLightClient()));
        vm.prank(address(admin));
        ctl.migrateRoute(clientId, "gnoland-9", type(uint64).max);

        assertEq(ctl.routeKey("gnoland-9"), clientId);
        assertEq(ctl.currentClient(clientId), "gnoland-9");
        assertTrue(ctl.isRetired(clientId));
        assertEq(ics20.getEscrow("gnoland-9"), escrow);
        assertEq(ics20.ibcERC20Contract("transfer/gnoland-9/ugnot"), address(ugnot));

        // the old id: no send, no receive
        _sendExpectRevert(
            alice, address(usdc), 1, clientId, abi.encodeWithSelector(T.GnoClientRetired.selector, clientId)
        );
        // the route is closed until reconciled and reopened (kinds 12, 13): no receive, no send, no claim
        assertTrue(ctl.routeClosed("gnoland-9"));
        assertTrue(_isErrorAck(_transferIn("gnoland-9", "ugnot", 10, bob)));
        _sendExpectRevert(
            alice, address(usdc), 1, "gnoland-9", abi.encodeWithSelector(T.GnoRouteClosed.selector, "gnoland-9")
        );
        vm.expectRevert(abi.encodeWithSelector(T.GnoRouteClosed.selector, "gnoland-9"));
        ctl.claim("gnoland-9", address(usdc), 1);
        // reopening waits for every record of the retired id: the packet still in flight is open
        assertEq(ctl.openRecords(clientId), 1);
        vm.prank(address(admin));
        vm.expectRevert(abi.encodeWithSelector(T.GnoRecordsOpen.selector, "gnoland-9", 1));
        ctl.reopenRoute("gnoland-9");
        _proveDelivered(out);
        T.SettleItem[] memory items = new T.SettleItem[](1);
        items[0] = T.SettleItem(out.sequence, 3, 0); // reconciled: delivered
        vm.startPrank(address(admin));
        ctl.settleRecords(clientId, items);
        ctl.reopenRoute("gnoland-9");
        vm.stopPrank();
        assertFalse(ctl.routeClosed(clientId));

        // the new id: the same voucher, escrow and limits (receive level kept)
        assertEq(ctl.limits("gnoland-9", address(ugnot)).receiveLevel, 50);
        assertTrue(_isSuccessAck(_transferIn("gnoland-9", "ugnot", 10, bob)));
        assertEq(ugnot.balanceOf(bob), 60);
        string memory usdcBack = string.concat("transfer/ethereum-2/", Strings.toHexString(address(usdc)));
        assertTrue(_isSuccessAck(_transferIn("gnoland-9", usdcBack, 100, bob)));
        assertEq(usdc.balanceOf(bob), 100);

        // a returning voucher names the new client id on the wire
        vm.prank(bob);
        ugnot.approve(address(ics20), type(uint256).max);
        IICS26RouterMsgs.Packet memory pkt = _send(bob, address(ugnot), 60, "gnoland-9");
        IICS20TransferMsgs.FungibleTokenPacketData memory data =
            abi.decode(pkt.payloads[0].value, (IICS20TransferMsgs.FungibleTokenPacketData));
        assertEq(data.denom, "transfer/gnoland-9/ugnot");
        assertEq(ugnot.totalSupply(), 0);
        // and its refund re-mints the same voucher
        _errorAck(pkt);
        assertEq(ugnot.balanceOf(bob), 60);
    }

    function test_migrateRoute_retiredReceive_errorAck() public {
        _addClient("gnoland-9", address(new MockLightClient()));
        vm.prank(address(admin));
        ctl.migrateRoute(clientId, "gnoland-9", type(uint64).max);
        assertTrue(_isErrorAck(_gnotIn(1, bob)));
    }

    function test_migrateRoute_refusesUsedIds() public {
        _addClient("gnoland-9", address(new MockLightClient()));
        vm.startPrank(address(admin));
        vm.expectRevert(T.GnoBadRoute.selector);
        ctl.migrateRoute(clientId, clientId, type(uint64).max);
        vm.expectRevert(T.GnoBadRoute.selector);
        ctl.migrateRoute(clientId, "", type(uint64).max);
        ctl.migrateRoute(clientId, "gnoland-9", type(uint64).max);
        vm.expectRevert(T.GnoBadRoute.selector);
        ctl.migrateRoute(clientId, "gnoland-10", type(uint64).max); // the old id is retired
        vm.expectRevert(T.GnoBadRoute.selector);
        ctl.migrateRoute("gnoland-9", clientId, type(uint64).max); // a retired id never comes back
        vm.stopPrank();
    }
}
