// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Vm } from "forge-std/Vm.sol";
import { ERC20Mock } from "@openzeppelin-contracts/mocks/token/ERC20Mock.sol";
import { IERC20 } from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import { IAccessManager } from "@openzeppelin-contracts/access/manager/IAccessManager.sol";
import { ISignatureTransfer } from "@uniswap/permit2/src/interfaces/ISignatureTransfer.sol";

import { IICS20Transfer } from "@eureka/interfaces/IICS20Transfer.sol";
import { IIBCSenderCallbacks } from "@eureka/interfaces/IIBCSenderCallbacks.sol";
import { IIBCAppCallbacks } from "@eureka/msgs/IIBCAppCallbacks.sol";
import { IICS26Router } from "@eureka/interfaces/IICS26Router.sol";
import { IICS26RouterMsgs } from "@eureka/msgs/IICS26RouterMsgs.sol";
import { IICS02ClientMsgs } from "@eureka/msgs/IICS02ClientMsgs.sol";
import { IICS20TransferMsgs } from "@eureka/msgs/IICS20TransferMsgs.sol";
import { Strings } from "@openzeppelin-contracts/utils/Strings.sol";
import { IBCRolesLib } from "@eureka/utils/IBCRolesLib.sol";
import { ICS24Host } from "@eureka/utils/ICS24Host.sol";
import { ICS20Lib } from "@eureka/utils/ICS20Lib.sol";

import { GnoICS20Transfer } from "../../src/GnoICS20Transfer.sol";
import { GnoICS20Controls } from "../../src/transfer/GnoICS20Controls.sol";
import { GnoICS20Reconcile } from "../../src/transfer/GnoICS20Reconcile.sol";
import { GnoICS20Evidence } from "../../src/transfer/GnoICS20Evidence.sol";
import { IGnoICS20ControlsTypes as T } from "../../src/interfaces/IGnoICS20Controls.sol";
import { IGuardians } from "../../src/interfaces/IGuardians.sol";
import { IIBCAdmin } from "../../src/interfaces/IIBCAdmin.sol";
import { IBCAdmin } from "../../src/admin/IBCAdmin.sol";
import { IBCAdminStorage as S } from "../../src/admin/IBCAdminStorage.sol";
import { GovParams as P } from "../utils/GovParams.sol";
import { MockLightClient } from "../utils/MockLightClient.sol";
import { RefusingToken } from "../utils/RefusingToken.sol";
import {
    MockPermit2,
    SenderAdapter,
    ReentrantToken,
    BeaconSwappingFork,
    AllowingExec,
    HookToken,
    OlderFork,
    GasBurnToken,
    CostlyBalanceToken,
    StatusMock,
    MuteRevertToken
} from "../utils/ControlsMocks.sol";
import { ICS26Router } from "@eureka/ICS26Router.sol";
import { ICS20Transfer } from "@eureka/ICS20Transfer.sol";
import { IICS02Client } from "@eureka/interfaces/IICS02Client.sol";
import { UpgradeableBeacon } from "@openzeppelin-contracts/proxy/beacon/UpgradeableBeacon.sol";
import { Escrow } from "@eureka/utils/Escrow.sol";
import { ControlsFixture } from "./ControlsFixture.sol";

/// @notice Regression tests for the second review of the Ethereum controls (findings numbered as in that review).
contract ReviewRegressionsTest is ControlsFixture {
    function _permit2() internal override returns (address) {
        return address(new MockPermit2());
    }

    function _decide(uint8 kind, bytes memory params) internal returns (uint64 seq) {
        seq = admin.lastSeq() + 1;
        assertEq(_status(_recvGov(_env(seq, kind, params))), S.STATUS_RECORDED);
    }

    function _state(uint64 seq) internal view returns (uint8) {
        return admin.decision(admin.epoch(), seq).state;
    }

    function _prefix() internal pure returns (bytes[] memory p) {
        p = new bytes[](2);
        p[0] = "main";
        p[1] = "/pv/vm:gno.land/r/aib/ibc/core:";
    }

    /// @notice Retires `clientId` by a direct migration (as IBCAdmin) to a fresh `gnoland-9`.
    function _retire() internal {
        address lc9 = address(new MockLightClient());
        vm.startPrank(address(admin));
        router.addClient("gnoland-9", IICS02ClientMsgs.CounterpartyInfo("ethereum-9", _prefix()), lc9);
        ctl.migrateRoute(clientId, "gnoland-9", type(uint64).max);
        vm.stopPrank();
    }

    function _settle(T.SettleItem[] memory items) internal {
        vm.prank(address(admin));
        ctl.settleRecords(clientId, items);
    }

    function _item(uint64 seq, uint8 action, uint256 amount) internal pure returns (T.SettleItem[] memory items) {
        items = new T.SettleItem[](1);
        items[0] = T.SettleItem(seq, action, amount);
    }

    // ===================================================================== #1 settle and reopen (kinds 12, 13) ==

    function test_r1_settle_eachActionOnce_allOrNothing() public {
        _setLimits(address(usdc), 1000, 1000, 1000);
        IICS26RouterMsgs.Packet memory forged = _send(alice, address(usdc), 100, clientId);
        IICS26RouterMsgs.Packet memory delivered = _send(alice, address(usdc), 200, clientId);
        IICS26RouterMsgs.Packet memory honest = _send(alice, address(usdc), 300, clientId);
        IICS26RouterMsgs.Packet memory inFlight = _send(alice, address(usdc), 400, clientId);
        _setLimits(address(usdc), 1000, 1000, 10); // a small refund meter
        _errorAck(forged); // a forged error ack of a delivered packet: queued
        ctl.claim(clientId, address(usdc), 1); // an installment of it is paid: 10
        _ack(delivered, bytes("{\"result\":\"AQ==\"}"));
        _ack(honest, bytes("{\"result\":\"AQ==\"}")); // a forged success ack of an undelivered packet
        _retire();
        _proveDelivered(forged);
        _proveDelivered(delivered);
        _proveRefundable(honest);
        _proveRefundable(inFlight);
        uint256 before = usdc.balanceOf(alice);

        // not for an id still in use
        vm.prank(address(admin));
        vm.expectRevert(abi.encodeWithSelector(T.GnoBadSettlement.selector, type(uint256).max));
        ctl.settleRecords("gnoland-9", _item(honest.sequence, 1, 300));
        // all or nothing: a refund cut short reverts the whole batch
        T.SettleItem[] memory bad = new T.SettleItem[](2);
        bad[0] = T.SettleItem(honest.sequence, 1, 300);
        bad[1] = T.SettleItem(inFlight.sequence, 1, 399);
        vm.prank(address(admin));
        vm.expectRevert(abi.encodeWithSelector(T.GnoBadSettlement.selector, 1));
        ctl.settleRecords(clientId, bad);
        // a forged refund's loss must be exactly what was paid
        vm.prank(address(admin));
        vm.expectRevert(abi.encodeWithSelector(T.GnoBadSettlement.selector, 0));
        ctl.settleRecords(clientId, _item(forged.sequence, 4, 0));
        assertEq(usdc.balanceOf(alice), before);

        T.SettleItem[] memory items = new T.SettleItem[](4);
        items[0] = T.SettleItem(forged.sequence, 4, 10); // forged refund: remainder rejected, 10 lost
        items[1] = T.SettleItem(delivered.sequence, 3, 0);
        items[2] = T.SettleItem(honest.sequence, 1, 300); // refund the undelivered packet in full
        items[3] = T.SettleItem(inFlight.sequence, 1, 400);
        _settle(items);
        assertEq(usdc.balanceOf(alice), before + 700);
        assertEq(uint8(ctl.sendRecord(clientId, forged.sequence).payment), uint8(T.Payment.Rejected));
        assertEq(ctl.sendRecord(clientId, delivered.sequence).settlement, 3);
        assertEq(ctl.losses(clientId, address(usdc)), 10);

        // each record at most once
        vm.prank(address(admin));
        vm.expectRevert(abi.encodeWithSelector(T.GnoBadSettlement.selector, 0));
        ctl.settleRecords(clientId, _item(honest.sequence, 1, 0));
        // the forged refund's remainder is never paid: it leaves the queue without a payment
        vm.prank(address(admin));
        ctl.reopenRoute(clientId);
        _skip(30 days);
        assertEq(ctl.claim(clientId, address(usdc), 10), 1);
        assertEq(usdc.balanceOf(alice), before + 700);
        assertEq(ctl.sendRecord(clientId, forged.sequence).refunded, 10);
        vm.prank(address(admin));
        vm.expectRevert(abi.encodeWithSelector(T.GnoNotClosed.selector, clientId));
        ctl.reopenRoute(clientId);
    }

    function test_r1_settledRefund_neverCutShort_parkedInFull() public {
        RefusingToken r = new RefusingToken();
        r.mint(alice, 1000);
        vm.prank(alice);
        r.approve(address(ics20), type(uint256).max);
        _setLimits(address(r), 1000, 1000, 1000);
        IICS26RouterMsgs.Packet memory pkt = _send(alice, address(r), 500, clientId);
        _retire();
        _proveRefundable(pkt);
        vm.prank(address(admin));
        vm.expectRevert(abi.encodeWithSelector(T.GnoBadSettlement.selector, 0));
        ctl.settleRecords(clientId, _item(pkt.sequence, 1, 200)); // a haircut is refused
        r.setBlocked(alice, true);
        _settle(_item(pkt.sequence, 1, 500));
        assertEq(uint8(ctl.sendRecord(clientId, pkt.sequence).payment), uint8(T.Payment.Parked));
        r.setBlocked(alice, false);
        vm.prank(address(admin));
        ctl.reopenRoute(clientId);
        assertEq(ctl.claimParked(clientId, pkt.sequence, 0), 500);
        assertEq(r.balanceOf(alice), 1000);
    }

    function test_r1_settleAndReopen_byDecision() public {
        IICS26RouterMsgs.Packet memory pkt;
        _setLimits(address(usdc), 1000, 1000, 1000);
        pkt = _send(alice, address(usdc), 100, clientId);
        _retire();
        _proveRefundable(pkt);
        uint64 settle = _decide(S.KIND_SETTLE, P.settle1(clientId, pkt.sequence, 1, 100));
        uint64 reopen = _decide(S.KIND_REOPEN, P.reopen("gnoland-9"));
        uint8 spent = _status(_recvGov(_env(admin.lastSeq() + 1, S.KIND_SETTLE, P.settle1(clientId, 1, 9, 1))));
        assertEq(spent, S.STATUS_SPENT, "unknown action");
        _skip(7 days);
        admin.execute(settle);
        admin.execute(reopen);
        assertFalse(ctl.routeClosed("gnoland-9"));
        assertEq(usdc.balanceOf(alice), 1_000_000e6);
    }

    /// @notice Round 2 #4: a retired client id is final, and a reconciled packet is refunded once: kind 6 cannot
    /// migrate the old id back, and even if the old client answered again, its timeout pays nothing.
    function test_r2_4_retiredIsFinal_reconciledPacketRefundedOnce() public {
        _setLimits(address(usdc), 1000, 1000, 1000);
        IICS26RouterMsgs.Packet memory pkt = _send(alice, address(usdc), 100, clientId);
        _retire();
        _proveRefundable(pkt);
        _settle(_item(pkt.sequence, 1, 100)); // not delivered: refunded by reconciliation
        assertEq(usdc.balanceOf(alice), 1_000_000e6);
        MockLightClient live = new MockLightClient();
        uint64 seq = _decide(S.KIND_CLIENT, P.client(2, clientId, CP, _prefix(), address(live), address(live).codehash));
        _skip(7 days);
        admin.execute(seq);
        assertEq(_state(seq), S.SPENT, "never migrated back");
        // whatever brings the old client back, an authentic timeout of the reconciled packet pays nothing
        IICS02ClientMsgs.CounterpartyInfo memory info = router.getCounterparty(clientId);
        vm.prank(address(admin));
        router.migrateClient(clientId, info, address(live));
        live.setTimestamp(pkt.timeoutTimestamp);
        router.timeoutPacket(IICS26RouterMsgs.MsgTimeoutPacket(pkt, "", IICS02ClientMsgs.Height(0, 1)));
        assertEq(usdc.balanceOf(alice), 1_000_000e6, "refunded once");
        assertEq(router.getCommitment(ICS24Host.packetCommitmentKeyCalldata(clientId, pkt.sequence)), bytes32(0));
        assertEq(uint8(ctl.sendRecord(clientId, pkt.sequence).payment), uint8(T.Payment.Claimed), "still settled");
        // nothing was queued for it either: reopened, the route pays nothing more
        vm.prank(address(admin));
        ctl.reopenRoute(clientId);
        _skip(1 days);
        assertEq(ctl.claim(clientId, address(usdc), 10), 0);
        assertEq(usdc.balanceOf(alice), 1_000_000e6, "refunded once");
    }

    /// @notice Round 2 #1: kind 13 waits until every record of the retired ids is reconciled (an outstanding packet,
    /// a queued refund), then accepts the recorded losses as the route's deficit.
    function test_r2_1_reopenWaitsForReconciliation_acceptsTheDeficit() public {
        _setLimits(address(usdc), 1000, 1000, 10);
        IICS26RouterMsgs.Packet memory forged = _send(alice, address(usdc), 100, clientId);
        IICS26RouterMsgs.Packet memory inFlight = _send(alice, address(usdc), 200, clientId);
        _errorAck(forged); // queued
        ctl.claim(clientId, address(usdc), 1); // 10 paid of it
        _retire();
        _proveDelivered(forged);
        _proveDelivered(inFlight);
        assertEq(ctl.openRecords(clientId), 2);
        vm.prank(address(admin));
        vm.expectRevert(abi.encodeWithSelector(T.GnoIncidentsPending.selector, clientId, 1));
        ctl.reopenRoute(clientId);
        _settle(_item(forged.sequence, 4, 10)); // the forged refund: 10 lost
        vm.prank(address(admin));
        vm.expectRevert(abi.encodeWithSelector(T.GnoIncidentsPending.selector, clientId, 1));
        ctl.reopenRoute(clientId);
        _settle(_item(inFlight.sequence, 3, 0));
        vm.expectEmit(true, true, false, true, address(ics20));
        emit T.GnoDeficitAccepted(clientId, address(usdc), 10);
        vm.prank(address(admin));
        ctl.reopenRoute(clientId);
        assertEq(ctl.acceptedDeficit(clientId, address(usdc)), 10);
        assertEq(ctl.losses(clientId, address(usdc)), 10);
    }

    /// @notice Round 2 #5: a parked reconciled refund keeps its backing after an accepted deficit: redemptions may
    /// not release the escrow reserved for it, and the refund is still payable once its sender takes tokens again.
    function test_r2_5_owedRefundsReserveTheirBacking() public {
        RefusingToken r = new RefusingToken();
        r.mint(alice, 100);
        r.mint(bob, 200);
        vm.prank(alice);
        r.approve(address(ics20), type(uint256).max);
        vm.prank(bob);
        r.approve(address(ics20), type(uint256).max);
        _setLimits(address(r), 1000, 1000, 1000);
        IICS26RouterMsgs.Packet memory pa = _send(alice, address(r), 100, clientId); // never delivered
        IICS26RouterMsgs.Packet memory pb = _send(bob, address(r), 200, clientId); // delivered: vouchers on gno
        address escrow = ics20.getEscrow(clientId);
        vm.prank(escrow);
        r.transfer(address(0xdead), 100); // an incident: 100 of the backing is gone
        _retire();
        _proveRefundable(pa);
        _proveDelivered(pb);
        r.setBlocked(alice, true);
        T.SettleItem[] memory items = new T.SettleItem[](2);
        items[0] = T.SettleItem(pa.sequence, 1, 100); // refunded in full: parked (alice refuses for now)
        items[1] = T.SettleItem(pb.sequence, 3, 0);
        _settle(items);
        assertEq(ctl.reserved(clientId, address(r)), 100);
        vm.prank(address(admin));
        ctl.reopenRoute(clientId); // the deficit is accepted
        // bob redeems his 200 vouchers: only what is not reserved can leave
        string memory back = string.concat("transfer/ethereum-9/", Strings.toHexString(address(r)));
        assertTrue(_isErrorAck(_transferIn("gnoland-9", back, 200, bob)), "would eat alice's refund");
        assertTrue(_isSuccessAck(_transferIn("gnoland-9", back, 100, bob)));
        assertTrue(_isErrorAck(_transferIn("gnoland-9", back, 1, bob)));
        // bob sends 100 more: outstanding, it is reserved too, so a redemption cannot spend it before its timeout
        r.mint(bob, 100);
        IICS26RouterMsgs.Packet memory pc = _send(bob, address(r), 100, "gnoland-9");
        assertEq(ctl.reserved(clientId, address(r)), 200);
        assertTrue(_isErrorAck(_transferIn("gnoland-9", back, 100, bob)), "would eat the outstanding send's backing");
        vm.warp(pc.timeoutTimestamp); // the new client's time
        router.timeoutPacket(IICS26RouterMsgs.MsgTimeoutPacket(pc, "", IICS02ClientMsgs.Height(0, 1)));
        // not delivered: refunded at once, from its own backing
        assertEq(r.balanceOf(bob), 200);
        assertEq(ctl.reserved(clientId, address(r)), 100);
        r.setBlocked(alice, false);
        assertEq(ctl.claimParked(clientId, pa.sequence, 0), 100);
        assertEq(r.balanceOf(alice), 100);
        assertEq(ctl.reserved(clientId, address(r)), 0);
    }

    /// @notice Round 5 #1: a refund that would release escrow below the other records' reservations is parked, never
    /// paid from their backing; it is paid once the backing is restored.
    function test_r5_1_refundBelowOtherReservations_isParked() public {
        _setLimits(address(usdc), 1000, 1000, 1000);
        IICS26RouterMsgs.Packet memory a = _send(alice, address(usdc), 100, clientId);
        IICS26RouterMsgs.Packet memory b = _send(alice, address(usdc), 100, clientId);
        address escrow = ics20.getEscrow(clientId);
        vm.prank(escrow);
        usdc.transfer(address(0xdead), 50); // an incident: escrow 150 for 200 outstanding
        uint256 before = usdc.balanceOf(alice);
        _timeout(a); // paying it would leave 50 for b's 100
        assertEq(uint8(ctl.sendRecord(clientId, a.sequence).payment), uint8(T.Payment.Parked));
        assertEq(usdc.balanceOf(alice), before);
        _ack(b, bytes("{\"result\":\"AQ==\"}")); // b delivered: its backing is free
        assertEq(ctl.claimParked(clientId, a.sequence, 0), 100);
        assertEq(usdc.balanceOf(alice), before + 100);
    }

    // ================================================================== #2 never spent by starving (proxies) ==

    function test_r2_gasSweep_routeReplacement_throughTheFallback() public {
        MockLightClient lc2 = new MockLightClient();
        uint64 add = _decide(
            S.KIND_CLIENT, P.client(1, "gnoland-2", "ethereum-2", _prefix(), address(lc2), address(lc2).codehash)
        );
        uint64 replace = _decide(S.KIND_ROUTE, P.route(clientId, "gnoland-2"));
        _skip(7 days);
        admin.execute(add);
        for (uint256 g = 100_000; g < 3_000_000; g += 25_000) {
            (bool ok,) = address(admin).call{ gas: g }(abi.encodeCall(admin.execute, (replace)));
            if (ok) break;
            assertEq(_state(replace), S.PENDING, "a starved execution pends");
        }
        assertEq(admin.epoch(), 2, "executed, not spent");
    }

    function test_r2_gasSweep_upgradeSelfStep() public {
        address impl = address(
            new GnoICS20Transfer(
                address(new GnoICS20Controls(address(new GnoICS20Reconcile(address(new GnoICS20Evidence())))))
            )
        );
        uint64 seq = _decide(S.KIND_UPGRADE, P.upgrade(address(ics20), impl, impl.codehash, ""));
        _skip(7 days);
        for (uint256 g = 100_000; g < 6_000_000; g += 100_000) {
            (bool ok,) = address(admin).call{ gas: g }(abi.encodeCall(admin.execute, (seq)));
            if (ok) break;
            assertEq(_state(seq), S.PENDING, "a starved upgrade pends");
        }
        assertEq(_state(seq), S.EXECUTED);
    }

    // ======================================================================= #3 refunds hold blocks unpause ==

    function test_r3_unpauseSpentUnderARefundsHold() public {
        vm.prank(G[0]);
        ctl.setRefundsFlag(clientId);
        vm.prank(G[1]);
        ctl.setRefundsFlag(clientId);
        _skip(12);
        uint64 seq = _decide(S.KIND_UNPAUSE, P.unpause(1, clientId));
        _skip(1 days);
        admin.execute(seq);
        assertEq(_state(seq), S.SPENT);
        assertTrue(ctl.refundsHeld(clientId));
    }

    // ================================================================ #4 a cap change never rewrites the past ==

    function test_r4_lowerCap_afterFullDrain() public {
        _setLimits(clientId, address(ugnot), T.Limits(100, 100, 100, 0, 0));
        assertTrue(_isSuccessAck(_gnotIn(100, bob)));
        _skip(1 days); // drained in full at 100/day
        _setLimits(clientId, address(ugnot), T.Limits(1, 1, 1, 0, 0));
        assertEq(ctl.limits(clientId, address(ugnot)).receiveLevel, 0);
        assertTrue(_isSuccessAck(_gnotIn(1, bob)));
    }

    // ============================================================ #6 senders notified only once refunds are paid ==

    function test_r6_contractSender_queuedRefund_notifiedAtClaim() public {
        SenderAdapter adapter = new SenderAdapter(IICS20Transfer(address(ics20)), IERC20(address(usdc)), bob);
        usdc.mint(address(adapter), 500);
        _setLimits(address(usdc), 1000, 1000, 10);
        vm.recordLogs();
        uint64 seq = adapter.send(500, clientId);
        IICS26RouterMsgs.Packet memory pkt = _sentPacket();
        assertEq(pkt.sequence, seq);
        _errorAck(pkt); // beyond the meter: queued, the adapter is not told yet (it has nothing to forward)
        assertEq(adapter.notices(), 0);
        assertEq(uint8(ctl.sendRecord(clientId, seq).payment), uint8(T.Payment.Queued));
        _skip(60 days);
        for (uint256 i = 0; i < 60 && ctl.sendRecord(clientId, seq).payment == T.Payment.Queued; i++) {
            ctl.claim(clientId, address(usdc), 1);
            _skip(1 days);
        }
        // paid in full: the notification is due; anyone delivers it with its bytes (only its hash is stored)
        assertEq(adapter.notices(), 0);
        assertTrue(ctl.retryNotification(clientId, seq, _errorNotice(pkt), 0));
        assertEq(adapter.notices(), 1);
        assertEq(usdc.balanceOf(bob), 500, "the adapter forwarded the paid refund");
    }

    function test_r6_failingNotification_neverRollsTheRefundBack() public {
        SenderAdapter adapter = new SenderAdapter(IICS20Transfer(address(ics20)), IERC20(address(usdc)), bob);
        usdc.mint(address(adapter), 1000);
        adapter.setRefuse(true);
        _setLimits(address(usdc), 1000, 1000, 1000);
        vm.recordLogs();
        adapter.send(500, clientId);
        IICS26RouterMsgs.Packet memory pkt = _sentPacket();
        lc.setTimestamp(pkt.timeoutTimestamp);
        vm.expectEmit(false, true, false, true, address(ics20));
        emit T.GnoSenderNotified(clientId, pkt.sequence, false);
        router.timeoutPacket(IICS26RouterMsgs.MsgTimeoutPacket(pkt, "", IICS02ClientMsgs.Height(0, 1)));
        assertEq(usdc.balanceOf(address(adapter)), 1000, "refund paid although the notification failed");
    }

    function _sentPacket() internal returns (IICS26RouterMsgs.Packet memory) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(router) && logs[i].topics[0] == IICS26Router.SendPacket.selector) {
                return abi.decode(logs[i].data, (IICS26RouterMsgs.Packet));
            }
        }
        revert("no packet");
    }

    // ========================================================== #10 suspended revocations during a recovery ==
    // (in IBCAdminRecovery.t.sol: needs the recovery enabled)

    // ======================================================================= #12 recovery thresholds ==

    function _adminWith(uint8 threshold, uint8 cancelThreshold) internal returns (IBCAdmin) {
        return _adminWith(30 days, threshold, cancelThreshold);
    }

    function _adminWith(uint64 delay, uint8 threshold, uint8 cancelThreshold) internal returns (IBCAdmin) {
        return new IBCAdmin(
            IBCAdmin.Config({
                router: address(router),
                accessManager: d.accessManager,
                ics20: address(ics20),
                exec: d.ibcAdminExec,
                govClientId: clientId,
                gnoChainId: "gno-test",
                seats: G,
                watch: W,
                recovery: IIBCAdmin.RecoveryConfig(delay, threshold, cancelThreshold, 30 days, 14 days)
            })
        );
    }

    function test_r12_recoveryNeedsASupermajority() public {
        vm.expectRevert(IIBCAdmin.RecoveryState.selector);
        _adminWith(2, 2);
        vm.expectRevert(IIBCAdmin.RecoveryState.selector);
        _adminWith(3, 1);
        vm.expectRevert(IIBCAdmin.RecoveryState.selector);
        _adminWith(5, 2);
        // r11 #4: cancelling needs a guardian majority too, three of four (ADR §7.12 step 3)
        vm.expectRevert(IIBCAdmin.RecoveryState.selector);
        _adminWith(3, 2);
        _adminWith(3, 3);
        _adminWith(4, 4);
    }

    // ====================================================================== #15 quarantine deadlines ==

    function _setQ(uint64 q) internal {
        vm.prank(address(admin));
        ctl.setQuarantine(clientId, q);
    }

    function test_r15_lengtheningKeepsAStartedDeadline() public {
        lc.setTransitionTime(uint64(_now()));
        uint256 t = _now();
        _skip(3 days);
        _setQ(14 days);
        vm.warp(t + 7 days);
        assertTrue(_isSuccessAck(_gnotIn(1, bob)), "the 7-day deadline stands");
    }

    function test_r15_lengtheningAfterExpiryRestartsNothing() public {
        lc.setTransitionTime(uint64(_now()));
        _skip(8 days);
        _setQ(14 days);
        assertTrue(_isSuccessAck(_gnotIn(1, bob)));
    }

    function test_r15_shorteningKeepsAStartedDeadline_laterTransitionsUseTheNewDuration() public {
        lc.setTransitionTime(uint64(_now()));
        uint256 t = _now();
        _skip(1 days);
        _setQ(1 days);
        assertTrue(_isErrorAck(_gnotIn(1, bob)), "still within the 7 days");
        vm.warp(t + 7 days);
        assertTrue(_isSuccessAck(_gnotIn(1, bob)));
        lc.setTransitionTime(uint64(_now()));
        _skip(1 days - 1);
        assertTrue(_isErrorAck(_gnotIn(1, bob)));
        _skip(1);
        assertTrue(_isSuccessAck(_gnotIn(1, bob)));
    }

    /// @notice Round 2 #7: two transitions at one block time, a duration enabled between them: the second is
    /// quarantined (transitions are told apart by number, not time).
    function test_r2_7_sameBlockTransitions_toldApart() public {
        _setQ(0);
        lc.setTransitionTime(uint64(_now())); // A, while disabled
        _setQ(7 days);
        lc.setTransitionTime(uint64(_now())); // B, same block time, after the change
        assertTrue(_isErrorAck(_gnotIn(1, bob)), "B is quarantined");
        _skip(7 days);
        assertTrue(_isSuccessAck(_gnotIn(1, bob)));
    }

    /// @notice Round 2 #6: a duration change named by a retired id reads the route's current client, so an active
    /// quarantine of the new client keeps its deadline.
    function test_r2_6_quarantineChangeThroughARetiredId() public {
        MockLightClient lc9 = new MockLightClient();
        vm.startPrank(address(admin));
        router.addClient("gnoland-9", IICS02ClientMsgs.CounterpartyInfo("ethereum-9", _prefix()), address(lc9));
        ctl.migrateRoute(clientId, "gnoland-9", type(uint64).max);
        ctl.reopenRoute("gnoland-9");
        vm.stopPrank();
        lc9.setTransitionTime(uint64(_now()));
        assertTrue(_isErrorAck(_transferIn("gnoland-9", "ugnot", 1, bob)));
        _setQ(0); // named by the retired id
        assertTrue(_isErrorAck(_transferIn("gnoland-9", "ugnot", 1, bob)), "the started quarantine stands");
        _skip(7 days);
        assertTrue(_isSuccessAck(_transferIn("gnoland-9", "ugnot", 1, bob)));
    }

    /// @notice Round 2 #8: a notification that failed is kept; once the sender takes callbacks again anyone retries
    /// it, and the retry never pays a second time.
    function test_r2_8_failedNotification_retried() public {
        SenderAdapter adapter = new SenderAdapter(IICS20Transfer(address(ics20)), IERC20(address(usdc)), bob);
        usdc.mint(address(adapter), 500);
        adapter.setRefuse(true);
        _setLimits(address(usdc), 1000, 1000, 1000);
        vm.recordLogs();
        adapter.send(500, clientId);
        IICS26RouterMsgs.Packet memory pkt = _sentPacket();
        vm.expectRevert(abi.encodeWithSelector(T.GnoNoNotification.selector, clientId, pkt.sequence));
        ctl.retryNotification(clientId, pkt.sequence, _timeoutNotice(pkt), 0); // nothing kept yet
        _timeout(pkt); // refund paid, notification refused
        assertEq(usdc.balanceOf(address(adapter)), 500);
        assertFalse(ctl.retryNotification(clientId, pkt.sequence, _timeoutNotice(pkt), 0)); // still refusing: kept
        adapter.setRefuse(false);
        bytes memory wrong = _errorNotice(pkt);
        vm.expectRevert(abi.encodeWithSelector(T.GnoNoNotification.selector, clientId, pkt.sequence));
        ctl.retryNotification(clientId, pkt.sequence, wrong, 0); // not the notification kept
        vm.prank(alice); // anyone
        assertTrue(ctl.retryNotification(clientId, pkt.sequence, _timeoutNotice(pkt), 0));
        assertEq(adapter.notices(), 1);
        assertEq(usdc.balanceOf(bob), 500, "forwarded the refund it was paid once");
        vm.expectRevert(abi.encodeWithSelector(T.GnoNoNotification.selector, clientId, pkt.sequence));
        ctl.retryNotification(clientId, pkt.sequence, _timeoutNotice(pkt), 0);
        assertEq(ctl.sendRecord(clientId, pkt.sequence).refunded, 500);
    }

    // ================================================================ #16, #18 port and envelope boundary ==

    function test_r18_envelope1024Recorded_1025Spent() public {
        // canonical parameters are a multiple of 32 bytes: the largest envelope within 1024 is 14 + 992 = 1006
        bytes memory params = P.settle1(string(_repeat("a", 32 * 24)), 1, 1, 1);
        bytes memory at = _env(1, S.KIND_SETTLE, params);
        assertEq(at.length, 1006);
        assertEq(_status(_recvGov(at)), S.STATUS_RECORDED);
        bytes memory over = _env(2, S.KIND_SETTLE, P.settle1(string(_repeat("a", 32 * 25)), 1, 1, 1));
        assertEq(over.length, 1038);
        assertEq(_status(_recvGov(over)), S.STATUS_SPENT);
        assertEq(admin.PORT(), "ibcgov");
        assertEq(admin.COUNTERPARTY_PORT(), "gov");
    }

    function _repeat(bytes1 c, uint256 n) internal pure returns (bytes memory b) {
        b = new bytes(n);
        for (uint256 i = 0; i < n; i++) {
            b[i] = c;
        }
    }

    /// @notice Round 8 #5: a decision's parameters must be exactly the canonical encoding of its tuple: trailing
    /// data, a non-canonical offset or dirty padding is spent at recording, never applied.
    function test_r8_5_nonCanonicalParams_spentAtRecording() public {
        bytes memory good = P.settings(clientId, 30 days); // a lengthening: applied at recording
        bytes memory trailing = bytes.concat(good, bytes32(0));
        bytes memory offset = bytes.concat(bytes32(uint256(0x60)), _slice(good, 32), bytes32(0)); // the string 32 later
        bytes memory padding = bytes.concat(good);
        padding[padding.length - 1] = 0x01; // a byte after the string's end
        bytes memory dirtyUint = bytes.concat(good);
        dirtyUint[32] = 0x01; // the uint64's high bytes
        bytes[4] memory bad = [trailing, offset, padding, dirtyUint];
        for (uint256 i = 0; i < 4; i++) {
            uint64 seq = admin.lastSeq() + 1;
            assertEq(_status(_recvGov(_env(seq, S.KIND_SETTINGS, bad[i]))), S.STATUS_SPENT, vm.toString(i));
        }
        assertEq(ctl.quarantineSeconds(clientId), 7 days, "none applied");
        uint64 ok = admin.lastSeq() + 1;
        assertEq(_status(_recvGov(_env(ok, S.KIND_SETTINGS, good))), S.STATUS_RECORDED);
        assertEq(ctl.quarantineSeconds(clientId), 30 days);
    }

    function _slice(bytes memory b, uint256 from) internal pure returns (bytes memory out) {
        out = new bytes(b.length - from);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = b[from + i];
        }
    }

    // ================================================================== #17 launch caps from the lock ==

    function test_r17_launchLimits_followTheExpectedLock() public pure {
        T.Limits memory l = _launchLimitsOf(100_000e6, 0, 0, 0); // 100,000 GNOT locked
        assertEq(l.dayCap, 10_000e6);
        assertEq(l.maxPerMessage, 10_000e6);
        assertEq(l.refundCap, 10_000e6);
        l = _launchLimitsOf(10_000_000e6, 0, 0, 0);
        assertEq(l.dayCap, 100_000e6);
        assertEq(l.maxPerMessage, 25_000e6);
        l = _launchLimitsOf(100_000e6, 1000e6, 5000e6, 0);
        assertEq(l.maxPerMessage, 1000e6);
        assertEq(l.dayCap, 5000e6);
        assertEq(l.refundCap, 5000e6);
    }

    function _launchLimitsOf(
        uint256 lock,
        uint256 m,
        uint256 day,
        uint256 refund
    )
        internal
        pure
        returns (T.Limits memory)
    {
        return _launchLimits(lock, m, day, refund);
    }

    function test_r17_overridesOnlyLower_andDeployRefusesMore() public {
        vm.expectRevert("overrides only lower");
        this.launchLimits(100_000e6, 0, 10_001e6, 0);
        Params memory p;
        p.deployer = deployer;
        p.lightClient = address(new MockLightClient());
        p.counterparty = CP;
        p.clientState.chainId = "gno-test";
        p.guardians = G;
        p.watch = W;
        p.expectedLock = 100_000e6;
        p.gnotLimits = T.Limits(25_000e6, 100_000e6, 100_000e6, 0, 0);
        vm.expectRevert("launch limits above the expected lock's");
        this.deployWith(p);
    }

    function launchLimits(uint256 lock, uint256 m, uint256 day, uint256 refund)
        external
        pure
        returns (T.Limits memory)
    {
        return _launchLimits(lock, m, day, refund);
    }

    function deployWith(Params memory p) external returns (Deployed memory) {
        return _deploy(p);
    }

    // ====================================================================== #19 a returning key ==

    function test_r19_aReturningKeyRevivesNoOldFlag() public {
        vm.prank(G[2]);
        ctl.setRouteFlag(clientId);
        address[6] memory k = [G[0], G[1], makeAddr("interim"), G[3], W[0], W[1]];
        vm.prank(address(admin));
        ctl.setGuardianKeys(k);
        assertFalse(ctl.routePaused(clientId));
        _skip(12);
        k[2] = G[2];
        vm.prank(address(admin));
        ctl.setGuardianKeys(k);
        assertFalse(ctl.routePaused(clientId), "the old flag stays dead");
        vm.prank(G[2]);
        ctl.setRouteFlag(clientId);
        assertTrue(ctl.routePaused(clientId));
    }

    /// @notice Round 3 #8: replacements C -> A -> B -> A executed in one block through IBCAdmin, A flagging the route
    /// while it held the seat the first time: the flag stays dead.
    function test_r3_8_sameBlockReturningKey_throughIBCAdmin() public {
        address a = makeAddr("key A");
        address b = makeAddr("key B");
        uint64 s1 = _decide(S.KIND_SEATS, P.seat1(5, a));
        uint64 s2 = _decide(S.KIND_SEATS, P.seat1(5, b));
        uint64 s3 = _decide(S.KIND_SEATS, P.seat1(5, a));
        _skip(7 days);
        admin.execute(s1);
        vm.prank(a);
        ctl.setRouteFlag(clientId);
        assertTrue(ctl.routePaused(clientId));
        admin.execute(s2);
        admin.execute(s3); // the same block: A holds the seat again
        assertFalse(ctl.routePaused(clientId), "A's old flag stays dead");
    }

    /// @notice Round 3 #7: kind 10 moves only to a client a governed kind 6 enrolled, never to one anybody created
    /// through the router's permissionless addClient.
    function test_r3_7_routeReplacementNeedsAnEnrolledClient() public {
        vm.prank(makeAddr("attacker"));
        string memory forged = router.addClient(
            IICS02ClientMsgs.CounterpartyInfo("ethereum-6", _prefix()), address(new MockLightClient())
        );
        assertEq(forged, "client-1");
        uint64 seq = _decide(S.KIND_ROUTE, P.route(clientId, forged));
        _skip(7 days);
        admin.execute(seq);
        assertEq(_state(seq), S.SPENT);
        assertEq(admin.epoch(), 1);
        assertFalse(ctl.isRetired(clientId));
    }

    /// @notice Round 3 #6: a refund already partly paid cannot be rejected (2) or called delivered (3): only a
    /// forged refund (4, booking the paid loss) or a genuine one (1) settles it.
    function test_r3_6_partlyPaidRefund_onlyForgedOrGenuine() public {
        _setLimits(address(usdc), 1000, 1000, 10);
        IICS26RouterMsgs.Packet memory pkt = _send(alice, address(usdc), 100, clientId);
        _errorAck(pkt);
        ctl.claim(clientId, address(usdc), 1); // 10 of it paid
        _retire();
        _proveDelivered(pkt);
        vm.startPrank(address(admin));
        vm.expectRevert(abi.encodeWithSelector(T.GnoBadSettlement.selector, 0));
        ctl.settleRecords(clientId, _item(pkt.sequence, 2, 0));
        vm.expectRevert(abi.encodeWithSelector(T.GnoBadSettlement.selector, 0));
        ctl.settleRecords(clientId, _item(pkt.sequence, 3, 0));
        ctl.settleRecords(clientId, _item(pkt.sequence, 4, 10));
        vm.stopPrank();
        assertEq(ctl.losses(clientId, address(usdc)), 10);
    }

    /// @notice The amended kind 12: a genuine refund already paid in full is settled with action 1 and amount zero,
    /// which moves nothing; the settlement cannot be replayed.
    function test_r3_fullyRefunded_settledWithZero_noReplay() public {
        _setLimits(address(usdc), 1000, 1000, 1000);
        IICS26RouterMsgs.Packet memory pkt = _send(alice, address(usdc), 100, clientId);
        _timeout(pkt); // refunded in full at once
        _retire();
        _proveRefundable(pkt);
        uint256 before = usdc.balanceOf(alice);
        vm.startPrank(address(admin));
        vm.expectRevert(abi.encodeWithSelector(T.GnoBadSettlement.selector, 0));
        ctl.settleRecords(clientId, _item(pkt.sequence, 1, 100)); // nothing is owed any more
        ctl.settleRecords(clientId, _item(pkt.sequence, 1, 0));
        vm.expectRevert(abi.encodeWithSelector(T.GnoBadSettlement.selector, 0));
        ctl.settleRecords(clientId, _item(pkt.sequence, 1, 0)); // a replay
        vm.stopPrank();
        assertEq(usdc.balanceOf(alice), before);
        assertEq(ctl.sendRecord(clientId, pkt.sequence).settlement, 1);
        assertEq(uint8(ctl.sendRecord(clientId, pkt.sequence).payment), uint8(T.Payment.Paid));
    }

    /// @notice Round 3 #2: a kind 7 call may not set any other code: neither beacon setter as the call, nor a call of
    /// the new code that re-points a beacon (an after-check), and the upgrade rolls back whole.
    function test_r3_2_upgradeCallNeverSwapsABeacon() public {
        address controls =
            address(new GnoICS20Controls(address(new GnoICS20Reconcile(address(new GnoICS20Evidence())))));
        address a = address(new GnoICS20Transfer(controls));
        address evil = address(new BeaconSwappingFork(controls));
        address unpinned = address(new Escrow());
        address escrowBeacon = IICS20Transfer(address(ics20)).getEscrowBeacon();
        address tokenBeacon = IICS20Transfer(address(ics20)).getIBCERC20Beacon();
        address escrowBefore = UpgradeableBeacon(escrowBeacon).implementation();
        address tokenBefore = UpgradeableBeacon(tokenBeacon).implementation();
        bytes32 implSlot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        bytes32 before = vm.load(address(ics20), implSlot);
        uint64 viaEscrow = _decide(
            S.KIND_UPGRADE,
            P.upgrade(address(ics20), a, a.codehash, abi.encodeWithSignature("upgradeEscrowTo(address)", unpinned))
        );
        uint64 viaToken = _decide(
            S.KIND_UPGRADE,
            P.upgrade(address(ics20), a, a.codehash, abi.encodeWithSignature("upgradeIBCERC20To(address)", unpinned))
        );
        uint64 viaCode = _decide(
            S.KIND_UPGRADE,
            P.upgrade(
                address(ics20), evil, evil.codehash, abi.encodeWithSignature("swapEscrowBeacon(address)", unpinned)
            )
        );
        _skip(7 days);
        admin.execute(viaEscrow);
        admin.execute(viaToken);
        admin.execute(viaCode);
        assertEq(_state(viaEscrow), S.SPENT);
        assertEq(_state(viaToken), S.SPENT);
        assertEq(_state(viaCode), S.SPENT);
        assertEq(UpgradeableBeacon(escrowBeacon).implementation(), escrowBefore);
        assertEq(UpgradeableBeacon(tokenBeacon).implementation(), tokenBefore);
        assertEq(vm.load(address(ics20), implSlot), before);
    }

    /// @notice Round 3 #5: a verifier swap (kind 6 migrate, scheduled before the transition) keeps the quarantine the
    /// old client's transition started; so does a route replacement.
    function test_r3_5_verifierSwapKeepsTheQuarantine() public {
        MockLightClient fresh = new MockLightClient();
        uint64 swap =
            _decide(S.KIND_CLIENT, P.client(2, clientId, CP, _prefix(), address(fresh), address(fresh).codehash));
        _skip(7 days);
        lc.setTransitionTime(uint64(_now()));
        uint256 t = _now();
        _skip(1 hours);
        admin.execute(swap);
        assertEq(address(router.getClient(clientId)), address(fresh));
        assertTrue(_isErrorAck(_gnotIn(1, bob)), "the started quarantine survives the swap");
        vm.warp(t + 7 days);
        assertTrue(_isSuccessAck(_gnotIn(1, bob)));
    }

    function test_r3_5_routeReplacementKeepsTheQuarantine() public {
        MockLightClient lc2 = new MockLightClient();
        uint64 add = _decide(
            S.KIND_CLIENT, P.client(1, "gnoland-2", "ethereum-2", _prefix(), address(lc2), address(lc2).codehash)
        );
        uint64 replace = _decide(S.KIND_ROUTE, P.route(clientId, "gnoland-2"));
        _skip(7 days);
        admin.execute(add);
        lc.setTransitionTime(uint64(_now()));
        uint256 t = _now();
        admin.execute(replace);
        vm.prank(address(admin));
        ctl.reopenRoute("gnoland-2");
        assertTrue(_isErrorAck(_transferIn("gnoland-2", "ugnot", 1, bob)), "kept across the replacement");
        vm.warp(t + 7 days);
        assertTrue(_isSuccessAck(_transferIn("gnoland-2", "ugnot", 1, bob)));
    }

    /// @notice Round 3 #4: a sender whose callback burns all its gas, with a 10,000-byte memo, cannot make a kind 12
    /// settlement fail (it would leave its record open and the route closed for good).
    function test_r3_4_gasBurningSender_cannotBlockSettlement() public {
        SenderAdapter adapter = new SenderAdapter(IICS20Transfer(address(ics20)), IERC20(address(usdc)), bob);
        usdc.mint(address(adapter), 500);
        _setLimits(address(usdc), 1000, 1000, 10);
        vm.recordLogs();
        adapter.sendWithMemo(500, clientId, string(new bytes(10_000)));
        IICS26RouterMsgs.Packet memory pkt = _sentPacket();
        _errorAck(pkt); // queued, its notification held
        adapter.setBurn(true);
        _retire();
        _proveRefundable(pkt);
        uint64 seq = _decide(S.KIND_SETTLE, P.settle1(clientId, pkt.sequence, 1, 500));
        _skip(7 days);
        admin.execute(seq);
        assertEq(_state(seq), S.EXECUTED, "settled, not spent");
        assertEq(usdc.balanceOf(address(adapter)), 500);
        assertEq(ctl.openRecords(clientId), 0);
        // the notification stays kept; a failing retry reads it but never rewrites its 10,000 bytes
        adapter.setBurn(false);
        adapter.setRefuse(true);
        uint256 g = gasleft();
        assertFalse(ctl.retryNotification(clientId, pkt.sequence, _errorNotice(pkt), 0));
        assertLt(g - gasleft(), 1_000_000, "kept, not rewritten");
        adapter.setRefuse(false);
        assertTrue(ctl.retryNotification(clientId, pkt.sequence, _errorNotice(pkt), 0));
        assertEq(usdc.balanceOf(bob), 500);
    }

    /// @notice Round 3 #3: losses in 70 tokens: kind 13 (through IBCAdmin.execute, its fixed budget) starts the
    /// reopening, anyone continues it in bounded batches, and the route opens with the last batch.
    function test_r3_3_manyLossTokens_reopenInBatches() public {
        uint256 n = 70;
        T.SettleItem[] memory items = new T.SettleItem[](n);
        address[] memory tokens = new address[](n);
        IICS26RouterMsgs.Packet[] memory pkts = new IICS26RouterMsgs.Packet[](n);
        for (uint256 i = 0; i < n; i++) {
            ERC20Mock t = new ERC20Mock();
            t.mint(alice, 10);
            vm.prank(alice);
            t.approve(address(ics20), type(uint256).max);
            _setLimits(address(t), 100, 100, 100);
            IICS26RouterMsgs.Packet memory pkt = _send(alice, address(t), 10, clientId);
            _errorAck(pkt); // a forged refund, paid at once
            items[i] = T.SettleItem(pkt.sequence, 4, 10);
            tokens[i] = address(t);
            pkts[i] = pkt;
        }
        _retire();
        for (uint256 i = 0; i < n; i++) {
            _proveDelivered(pkts[i]);
        }
        _settle(items);
        uint64 seq = _decide(S.KIND_REOPEN, P.reopen("gnoland-9"));
        _skip(7 days);
        admin.execute(seq);
        assertEq(_state(seq), S.EXECUTED);
        assertTrue(ctl.routeReopening(clientId));
        assertTrue(ctl.routeClosed(clientId), "closed until the last batch");
        assertTrue(_isErrorAck(_transferIn("gnoland-9", "ugnot", 1, bob)));
        vm.startPrank(bob); // anyone
        while (ctl.routeReopening(clientId)) {
            ctl.continueReopen(clientId, 16);
        }
        vm.stopPrank();
        assertFalse(ctl.routeClosed(clientId));
        for (uint256 i = 0; i < n; i++) {
            assertEq(ctl.acceptedDeficit(clientId, tokens[i]), 10);
        }
        assertTrue(_isSuccessAck(_transferIn("gnoland-9", "ugnot", 1, bob)));
    }

    /// @notice Round 3 #1: kind 10 names the start of the suspected compromise interval; every ack and timeout
    /// processed from it on (a forged success, a forged refund paid in full, a genuine refund paid in full) must be
    /// settled by kind 12 before kind 13 reopens the route; one processed before it need not be; and a retired id
    /// is never replaced again.
    function test_r3_1_suspectInterval_settledBeforeReopen() public {
        _setLimits(address(usdc), 1000, 1000, 1000);
        bytes memory ok = bytes("{\"result\":\"AQ==\"}");
        IICS26RouterMsgs.Packet memory before = _send(alice, address(usdc), 100, clientId);
        _ack(before, ok);
        vm.roll(block.number + 10);
        uint64 from = uint64(block.number);
        IICS26RouterMsgs.Packet memory forgedOk = _send(alice, address(usdc), 100, clientId);
        _ack(forgedOk, ok); // a forged success ack of an undelivered packet
        IICS26RouterMsgs.Packet memory forgedRefund = _send(alice, address(usdc), 100, clientId);
        _errorAck(forgedRefund); // paid at once
        IICS26RouterMsgs.Packet memory genuine = _send(alice, address(usdc), 100, clientId);
        _timeout(genuine); // paid at once
        vm.roll(block.number + 5);

        MockLightClient lc2 = new MockLightClient();
        uint64 add = _decide(
            S.KIND_CLIENT, P.client(1, "gnoland-2", "ethereum-2", _prefix(), address(lc2), address(lc2).codehash)
        );
        uint64 replace = _decide(S.KIND_ROUTE, P.route(clientId, "gnoland-2", from));
        _skip(7 days);
        admin.execute(add);
        admin.execute(replace);
        assertEq(admin.decision(1, replace).state, S.EXECUTED);
        (uint64 f, uint64 open) = ctl.suspectRecords(clientId);
        assertEq(f, from);
        assertEq(open, 3);
        assertEq(ctl.openRecords(clientId), 0, "nothing outstanding: the old gate alone would reopen");
        // the suspect successes reserved before any refund is paid (round 20)
        assertEq(ctl.prepareIncident(clientId, 16), 0);

        _proveDelivered(before);
        _proveRefundable(forgedOk);
        _proveDelivered(forgedRefund);
        _proveRefundable(genuine);
        vm.startPrank(address(admin));
        vm.expectRevert(abi.encodeWithSelector(T.GnoIncidentsPending.selector, "gnoland-2", 1));
        ctl.reopenRoute("gnoland-2");
        // only the route's current client is replaced (a replacement while closed is test_r7_1_…)
        vm.expectRevert(T.GnoBadRoute.selector);
        ctl.migrateRoute(clientId, "gnoland-8", 0);
        // a record processed before the interval does not count
        ctl.settleRecords(clientId, _item(before.sequence, 3, 0));
        (, open) = ctl.suspectRecords(clientId);
        assertEq(open, 3);
        uint256 paid = usdc.balanceOf(alice);
        ctl.settleRecords(clientId, _item(forgedOk.sequence, 1, 100)); // refunded now
        assertEq(usdc.balanceOf(alice), paid + 100);
        ctl.settleRecords(clientId, _item(forgedRefund.sequence, 4, 100)); // the paid loss, booked
        vm.expectRevert(abi.encodeWithSelector(T.GnoIncidentsPending.selector, "gnoland-2", 1));
        ctl.reopenRoute("gnoland-2");
        ctl.settleRecords(clientId, _item(genuine.sequence, 1, 0)); // already paid in full
        (, open) = ctl.suspectRecords(clientId);
        assertEq(open, 0);
        ctl.reopenRoute("gnoland-2");
        vm.stopPrank();
        assertFalse(ctl.routeClosed(clientId));
        assertEq(ctl.acceptedDeficit(clientId, address(usdc)), 100);
    }

    /// @notice Round 3 #1: an ack processed on the old id after the replacement (here a migration that does not
    /// freeze the old client) is inside the interval too: counted, and settled like the rest.
    function test_r3_1_lateAckDuringReconciliation_isCounted() public {
        _setLimits(address(usdc), 1000, 1000, 1000);
        IICS26RouterMsgs.Packet memory pkt = _send(alice, address(usdc), 100, clientId);
        address lc9 = address(new MockLightClient());
        vm.startPrank(address(admin));
        router.addClient("gnoland-9", IICS02ClientMsgs.CounterpartyInfo("ethereum-9", _prefix()), lc9);
        ctl.migrateRoute(clientId, "gnoland-9", uint64(block.number));
        vm.stopPrank();
        (, uint64 open) = ctl.suspectRecords(clientId);
        assertEq(open, 0);
        _errorAck(pkt); // queued: the route is closed
        (, open) = ctl.suspectRecords(clientId);
        assertEq(open, 1);
        _proveDelivered(pkt);
        vm.startPrank(address(admin));
        ctl.settleRecords(clientId, _item(pkt.sequence, 2, 0));
        ctl.reopenRoute("gnoland-9");
        vm.stopPrank();
        assertFalse(ctl.routeClosed(clientId));
    }

    // ====================================================================================== round 4 ==

    /// @notice Round 4 #3: a record processed in the block of the first replacement is reconciled by it; a second
    /// replacement, whatever its `suspectFrom`, never counts it again (it could not be settled twice, so the route
    /// could never reopen).
    function test_r4_3_secondReplacement_skipsRecordsAlreadyReconciled() public {
        _setLimits(address(usdc), 1000, 1000, 1000);
        IICS26RouterMsgs.Packet memory pkt = _send(alice, address(usdc), 100, clientId);
        _ack(pkt, bytes("{\"result\":\"AQ==\"}"));
        address lc9 = address(new MockLightClient());
        vm.startPrank(address(admin));
        router.addClient("gnoland-9", IICS02ClientMsgs.CounterpartyInfo("ethereum-9", _prefix()), lc9);
        ctl.migrateRoute(clientId, "gnoland-9", uint64(block.number)); // the same block as the ack
        (, uint64 open) = ctl.suspectRecords(clientId);
        assertEq(open, 1);
        _proveDelivered(pkt);
        ctl.settleRecords(clientId, _item(pkt.sequence, 3, 0));
        ctl.reopenRoute("gnoland-9");
        assertFalse(ctl.routeClosed(clientId));
        vm.roll(block.number + 1);
        router.addClient("gnoland-8", IICS02ClientMsgs.CounterpartyInfo("ethereum-8", _prefix()), lc9);
        ctl.migrateRoute("gnoland-9", "gnoland-8", 0);
        (, open) = ctl.suspectRecords("gnoland-8");
        assertEq(open, 0, "already reconciled");
        ctl.reopenRoute("gnoland-8");
        vm.stopPrank();
        assertFalse(ctl.routeClosed(clientId));
    }

    /// @notice Round 4 #1: a kind 7 migration call is empty or on the executor's pinned allow-list (empty at
    /// launch): an upgrade can carry no client migration (an unpinned verifier, a retired id, a quarantine skipped),
    /// no client addition and no admin call; a kind 9 hand-over to an executor with its own list admits that list.
    function test_r4_1_upgradeMigrationCall_onlyFromThePinnedAllowList() public {
        address routerImpl = address(new ICS26Router());
        address fork = address(
            new GnoICS20Transfer(
                address(new GnoICS20Controls(address(new GnoICS20Reconcile(address(new GnoICS20Evidence())))))
            )
        );
        address unpinned = address(new MockLightClient());
        IICS02ClientMsgs.CounterpartyInfo memory cp = IICS02ClientMsgs.CounterpartyInfo("ethereum-1", _prefix());
        bytes[5] memory calls = [
            abi.encodeWithSignature("migrateClient(string,(string,bytes[]),address)", clientId, cp, unpinned),
            abi.encodeWithSignature("addClient(string,(string,bytes[]),address)", "gnoland-7", cp, unpinned),
            abi.encodeWithSignature("addClient((string,bytes[]),address)", cp, unpinned),
            abi.encodeCall(IICS02Client.getClient, (clientId)),
            abi.encodeWithSignature("setCustomERC20(string,address)", "transfer/client-0/ugnot", address(usdc))
        ];
        uint64[5] memory seqs;
        for (uint256 i = 0; i < 4; i++) {
            seqs[i] = _decide(S.KIND_UPGRADE, P.upgrade(address(router), routerImpl, routerImpl.codehash, calls[i]));
        }
        seqs[4] = _decide(S.KIND_UPGRADE, P.upgrade(address(ics20), fork, fork.codehash, calls[4]));
        AllowingExec next = new AllowingExec(address(router), d.accessManager, address(ics20));
        uint64 handover = _decide(S.KIND_HANDOVER, P.handover(address(next), address(next).codehash, ""));
        address clientBefore = address(router.getClient(clientId));
        _skip(7 days);
        for (uint256 i = 0; i < 5; i++) {
            admin.execute(seqs[i]);
            assertEq(_state(seqs[i]), S.SPENT);
        }
        assertEq(address(router.getClient(clientId)), clientBefore);
        vm.expectRevert();
        router.getClient("gnoland-7");
        admin.execute(handover);
        assertEq(_state(handover), S.EXECUTED);
        uint64 allowed = _decide(S.KIND_UPGRADE, P.upgrade(address(router), routerImpl, routerImpl.codehash, calls[3]));
        uint64 still = _decide(S.KIND_UPGRADE, P.upgrade(address(router), routerImpl, routerImpl.codehash, calls[0]));
        _skip(7 days);
        admin.execute(allowed);
        admin.execute(still);
        assertEq(_state(allowed), S.EXECUTED);
        assertEq(_state(still), S.SPENT);
        assertEq(address(router.getClient(clientId)), clientBefore);
    }

    /// @notice Round 4 #2: kind 12, through IBCAdmin.execute and its fixed budget, settles refunds whose held
    /// notifications are 100,000 bytes each, alone and in a batch: it never loads them; anyone delivers them after.
    function test_r4_2_hugeNotifications_neverLoadedBySettlement() public {
        _setLimits(address(usdc), 1000, 1000, 1);
        string memory memo = string(new bytes(100_000));
        SenderAdapter[6] memory adapters;
        uint64[6] memory seqs;
        IICS26RouterMsgs.Packet[6] memory pkts;
        for (uint256 i = 0; i < 6; i++) {
            adapters[i] = new SenderAdapter(IICS20Transfer(address(ics20)), IERC20(address(usdc)), bob);
            usdc.mint(address(adapters[i]), 100);
            vm.recordLogs();
            adapters[i].sendWithMemo(100, clientId, memo);
            IICS26RouterMsgs.Packet memory pkt = _sentPacket();
            seqs[i] = pkt.sequence;
            pkts[i] = pkt;
            _errorAck(pkt); // queued under the refund meter, its 100,000-byte notification held
        }
        _retire();
        for (uint256 i = 0; i < 6; i++) {
            _proveRefundable(pkts[i]);
        }
        uint64 single = _decide(S.KIND_SETTLE, P.settle1(clientId, seqs[0], 1, 100));
        P.SettleItem[] memory items = new P.SettleItem[](5);
        for (uint256 i = 0; i < 5; i++) {
            items[i] = P.SettleItem(seqs[i + 1], 1, 100);
        }
        uint64 batch = _decide(S.KIND_SETTLE, P.settle(clientId, items));
        _skip(7 days);
        admin.execute{ gas: 8_000_000 }(single);
        admin.execute{ gas: 8_000_000 }(batch);
        assertEq(_state(single), S.EXECUTED, "settled, not spent");
        assertEq(_state(batch), S.EXECUTED, "settled, not spent");
        assertEq(ctl.openRecords(clientId), 0);
        for (uint256 i = 0; i < 6; i++) {
            assertEq(usdc.balanceOf(address(adapters[i])), 100, "refunded");
            assertEq(adapters[i].notices(), 0, "nothing delivered by the settlement");
            assertTrue(ctl.retryNotification(clientId, seqs[i], _errorNotice(pkts[i]), 0));
            assertEq(adapters[i].notices(), 1);
            assertEq(usdc.balanceOf(address(adapters[i])), 0, "forwarded on its notification");
        }
        assertEq(usdc.balanceOf(bob), 600);
    }

    /// @notice Round 4 #6: a contract sender whose packet was still outstanding at the replacement is refunded by
    /// kind 12 with no ack or timeout, so no notification was ever held; anyone builds it from the authenticated
    /// packet (`notifySettled`), delivered once, retried after a failure. The adapter takes callbacks only from the
    /// transfer app and forwards the refund only on one.
    function test_r4_6_outstandingPacketRefund_notifiesTheSender() public {
        SenderAdapter adapter = new SenderAdapter(IICS20Transfer(address(ics20)), IERC20(address(usdc)), bob);
        usdc.mint(address(adapter), 100);
        _setLimits(address(usdc), 1000, 1000, 1000);
        vm.recordLogs();
        adapter.send(100, clientId);
        IICS26RouterMsgs.Packet memory pkt = _sentPacket(); // never acknowledged nor timed out
        _retire();
        _proveRefundable(pkt);
        _settle(_item(pkt.sequence, 1, 100));
        assertEq(usdc.balanceOf(address(adapter)), 100);
        vm.expectRevert(abi.encodeWithSelector(T.GnoNoNotification.selector, clientId, pkt.sequence));
        ctl.retryNotification(clientId, pkt.sequence, _timeoutNotice(pkt), 0);
        // a packet that is not the record's is refused
        IICS26RouterMsgs.Packet memory other = _sentPacketCopy(pkt);
        other.timeoutTimestamp += 1;
        vm.expectRevert(abi.encodeWithSelector(T.GnoNoNotification.selector, clientId, pkt.sequence));
        ctl.notifySettled(other, "", 0);
        adapter.setRefuse(true);
        vm.prank(makeAddr("anyone"));
        assertFalse(ctl.notifySettled(pkt, "", 0));
        adapter.setRefuse(false);
        vm.prank(makeAddr("anyone"));
        assertTrue(ctl.notifySettled(pkt, "", 0));
        assertEq(adapter.notices(), 1);
        assertEq(usdc.balanceOf(bob), 100, "forwarded on the notification");
        vm.expectRevert(abi.encodeWithSelector(T.GnoNoNotification.selector, clientId, pkt.sequence));
        ctl.notifySettled(pkt, "", 0); // once
    }

    function _sentPacketCopy(IICS26RouterMsgs.Packet memory p) internal pure returns (IICS26RouterMsgs.Packet memory) {
        return abi.decode(abi.encode(p), (IICS26RouterMsgs.Packet));
    }

    /// @notice Round 4 #5: a forged receive that released escrow has no send record; kind 12 action 5 books it as a
    /// loss, once, for exactly the amount the receive recorded, and kind 13 accepts it as a deficit.
    function test_r4_5_forgedEscrowRelease_bookedAndAccepted() public {
        _setLimits(address(usdc), 1000, 1000, 1000);
        IICS26RouterMsgs.Packet memory sent = _send(alice, address(usdc), 100, clientId);
        _ack(sent, bytes("{\"result\":\"AQ==\"}"));
        // a forged packet the compromised client accepted: it releases the escrow to bob
        string memory usdcBack = string.concat("transfer/", CP, "/", Strings.toHexString(address(usdc)));
        assertTrue(_isSuccessAck(_transferIn(clientId, usdcBack, 100, bob)));
        uint64 inbound = nextRecvSeq[keccak256(bytes(clientId))];
        (address token, uint256 amount) = ctl.receiveRecord(clientId, inbound);
        assertEq(token, address(usdc));
        assertEq(amount, 100);
        uint64 replace = _decide(S.KIND_ROUTE, P.route(clientId, "gnoland-2", 0));
        MockLightClient lc2 = new MockLightClient();
        uint64 add = _decide(
            S.KIND_CLIENT, P.client(1, "gnoland-2", "ethereum-2", _prefix(), address(lc2), address(lc2).codehash)
        );
        _skip(7 days);
        admin.execute(add);
        admin.execute(replace);
        _proveDelivered(sent);
        vm.startPrank(address(admin));
        ctl.settleRecords(clientId, _item(sent.sequence, 3, 0)); // the honest send was delivered
        vm.expectRevert(abi.encodeWithSelector(T.GnoBadSettlement.selector, 0));
        ctl.settleRecords(clientId, _item(inbound, 5, 99)); // not the recorded amount
        vm.expectRevert(abi.encodeWithSelector(T.GnoBadSettlement.selector, 0));
        ctl.settleRecords(clientId, _item(inbound + 1, 5, 100)); // no such receive
        ctl.settleRecords(clientId, _item(inbound, 5, 100));
        vm.expectRevert(abi.encodeWithSelector(T.GnoBadSettlement.selector, 0));
        ctl.settleRecords(clientId, _item(inbound, 5, 100)); // once
        assertEq(ctl.losses(clientId, address(usdc)), 100);
        ctl.reopenRoute("gnoland-2");
        vm.stopPrank();
        assertFalse(ctl.routeClosed(clientId));
        assertEq(ctl.acceptedDeficit(clientId, address(usdc)), 100);
    }

    // ====================================================================================== round 5 ==

    /// @notice Round 5 #4: losses in 17 tokens; kind 13 accepts 16, then a matured kind 12 would add a loss to the
    /// first token behind the cursor. Reconciliation is sealed while the route reopens: that kind 12 is spent, and
    /// the route opens with every loss accepted.
    function test_r5_4_settlementSealedWhileReopening() public {
        uint256 n = 17;
        T.SettleItem[] memory items = new T.SettleItem[](n);
        ERC20Mock[] memory tokens = new ERC20Mock[](n);
        IICS26RouterMsgs.Packet[] memory pkts = new IICS26RouterMsgs.Packet[](n);
        for (uint256 i = 0; i < n; i++) {
            tokens[i] = new ERC20Mock();
            tokens[i].mint(alice, 20);
            vm.prank(alice);
            tokens[i].approve(address(ics20), type(uint256).max);
            _setLimits(address(tokens[i]), 100, 100, 100);
            pkts[i] = _send(alice, address(tokens[i]), 10, clientId);
            _errorAck(pkts[i]); // a forged refund, paid at once
            items[i] = T.SettleItem(pkts[i].sequence, 4, 10);
        }
        IICS26RouterMsgs.Packet memory late = _send(alice, address(tokens[0]), 10, clientId);
        _errorAck(late); // another forged refund of the first token, settled late
        _retire();
        for (uint256 i = 0; i < n; i++) {
            _proveDelivered(pkts[i]);
        }
        _proveDelivered(late);
        _settle(items);
        uint64 reopen = _decide(S.KIND_REOPEN, P.reopen("gnoland-9"));
        uint64 settleLate = _decide(S.KIND_SETTLE, P.settle1(clientId, late.sequence, 4, 10));
        _skip(7 days);
        admin.execute(reopen);
        assertTrue(ctl.routeReopening(clientId));
        vm.prank(address(admin));
        vm.expectRevert(abi.encodeWithSelector(T.GnoRouteReopening.selector, clientId));
        ctl.settleRecords(clientId, _item(late.sequence, 4, 10));
        admin.execute(settleLate);
        assertEq(_state(settleLate), S.SPENT, "sealed while reopening");
        ctl.continueReopen(clientId, 16);
        assertFalse(ctl.routeClosed(clientId));
        for (uint256 i = 0; i < n; i++) {
            assertEq(ctl.acceptedDeficit(clientId, address(tokens[i])), ctl.losses(clientId, address(tokens[i])));
        }
    }

    /// @notice Round 5 #5: the first refund's token freezes the verifier from its transfer hook; the batch, whose
    /// outcomes were proven by that verifier, rolls back whole (since round 17 by the check after the last payment,
    /// every item being validated before any payment). A lone item whose own payment freezes it
    /// rolls back too (checked after the last payment).
    function test_r5_5_verifierFrozenByAPaymentHook_rollsTheBatchBack() public {
        HookToken h = new HookToken();
        h.mint(alice, 300);
        vm.prank(alice);
        h.approve(address(ics20), type(uint256).max);
        _setLimits(address(h), 1000, 1000, 1000);
        IICS26RouterMsgs.Packet memory a = _send(alice, address(h), 100, clientId);
        IICS26RouterMsgs.Packet memory b = _send(alice, address(h), 200, clientId);
        _retire();
        _proveRefundable(a);
        _proveRefundable(b);
        address lc9 = address(router.getClient("gnoland-9"));
        bytes memory freeze = abi.encodeCall(MockLightClient.setStatus, (true, false));
        T.SettleItem[] memory items = new T.SettleItem[](2);
        items[0] = T.SettleItem(a.sequence, 1, 100);
        items[1] = T.SettleItem(b.sequence, 1, 200);
        h.setHook(alice, lc9, freeze);
        vm.prank(address(admin));
        // every item is validated before any payment (round 17): the check after the last payment refuses it
        vm.expectRevert(abi.encodeWithSelector(T.GnoBadSettlement.selector, type(uint256).max));
        ctl.settleRecords(clientId, items);
        h.setHook(alice, lc9, freeze);
        vm.prank(address(admin));
        vm.expectRevert(abi.encodeWithSelector(T.GnoBadSettlement.selector, type(uint256).max));
        ctl.settleRecords(clientId, _item(a.sequence, 1, 100));
        // through IBCAdmin: spent, nothing paid
        h.setHook(alice, lc9, freeze);
        uint64 seq = _decide(S.KIND_SETTLE, P.settle(clientId, _p(items)));
        _skip(7 days);
        admin.execute(seq);
        assertEq(_state(seq), S.SPENT);
        assertEq(h.balanceOf(alice), 0);
        assertEq(ctl.openRecords(clientId), 2);
    }

    function _p(T.SettleItem[] memory items) internal pure returns (P.SettleItem[] memory out) {
        out = new P.SettleItem[](items.length);
        for (uint256 i = 0; i < items.length; i++) {
            out[i] = P.SettleItem(items[i].sequence, items[i].action, items[i].amount);
        }
    }

    /// @notice Round 5 sweep (a): an outcome is bound to its verifier and the route's verifier generation. A kind 6
    /// swap to another client and back to the same one voids it; it is proven again through the active client.
    function test_r5_5_verifierSwappedAndBack_voidsTheOutcome() public {
        _setLimits(address(usdc), 1000, 1000, 1000);
        IICS26RouterMsgs.Packet memory pkt = _send(alice, address(usdc), 100, clientId);
        _retire();
        _proveRefundable(pkt);
        address lc9 = address(router.getClient("gnoland-9"));
        MockLightClient other = new MockLightClient();
        uint64 away = _decide(
            S.KIND_CLIENT, P.client(2, "gnoland-9", "ethereum-9", _prefix(), address(other), address(other).codehash)
        );
        uint64 back = _decide(S.KIND_CLIENT, P.client(2, "gnoland-9", "ethereum-9", _prefix(), lc9, lc9.codehash));
        _skip(7 days);
        admin.execute(away);
        admin.execute(back);
        assertEq(_state(back), S.EXECUTED);
        assertEq(address(router.getClient("gnoland-9")), lc9, "the same verifier again");
        vm.prank(address(admin));
        vm.expectRevert(abi.encodeWithSelector(T.GnoBadSettlement.selector, 0));
        ctl.settleRecords(clientId, _item(pkt.sequence, 1, 100));
        _proveRefundable(pkt); // void: proven again
        _settle(_item(pkt.sequence, 1, 100));
        assertEq(usdc.balanceOf(alice), 1_000_000e6);
    }

    /// @notice Round 5 #3: a contract sender's 100,000-byte memo of nonzero bytes: its error ack, the claims paying
    /// the queued refund and the notification's delivery each fit the 16,777,216-gas transaction cap (EIP-7825),
    /// since only the notification's hash is ever stored.
    function test_r5_3_hugeNonzeroMemo_underTheTransactionCap() public {
        uint256 cap = 16_777_216;
        SenderAdapter adapter = new SenderAdapter(IICS20Transfer(address(ics20)), IERC20(address(usdc)), bob);
        usdc.mint(address(adapter), 100);
        _setLimits(address(usdc), 1000, 1000, 50);
        bytes memory memo = new bytes(100_000);
        for (uint256 i = 0; i < memo.length; i++) {
            memo[i] = "a";
        }
        vm.recordLogs();
        adapter.sendWithMemo(100, clientId, string(memo));
        IICS26RouterMsgs.Packet memory pkt = _sentPacket();
        router.ackPacket{ gas: cap }(
            IICS26RouterMsgs.MsgAckPacket(pkt, ICS24Host.UNIVERSAL_ERROR_ACK, "", IICS02ClientMsgs.Height(0, 1))
        );
        assertEq(uint8(ctl.sendRecord(clientId, pkt.sequence).payment), uint8(T.Payment.Queued));
        _skip(1 days);
        ctl.claim{ gas: cap }(clientId, address(usdc), 1);
        _skip(1 days);
        ctl.claim{ gas: cap }(clientId, address(usdc), 1);
        assertEq(uint8(ctl.sendRecord(clientId, pkt.sequence).payment), uint8(T.Payment.Claimed));
        bytes memory notice = _errorNotice(pkt);
        assertTrue(ctl.retryNotification{ gas: cap }(clientId, pkt.sequence, notice, 0));
        assertEq(adapter.notices(), 1);
        assertEq(usdc.balanceOf(bob), 100);
    }

    /// @notice Round 5 #2: kind 7 never installs on the transfer proxy code that cannot keep the controls: the stock
    /// ICS20Transfer (no probe) or an older fork is spent, with a live route alias, a reservation and an unpaid
    /// refund in place; a compatible fork is installed.
    function test_r5_2_upgradeToStockOrOlderTransfer_isRefused() public {
        _setLimits(address(usdc), 1000, 1000, 10);
        IICS26RouterMsgs.Packet memory sent = _send(alice, address(usdc), 100, clientId);
        _ack(sent, bytes("{\"result\":\"AQ==\"}"));
        _retire();
        _proveDelivered(sent);
        _settle(_item(sent.sequence, 3, 0));
        vm.prank(address(admin));
        ctl.reopenRoute("gnoland-9"); // a live route alias: gnoland-9 -> client-0
        IICS26RouterMsgs.Packet memory owed = _send(alice, address(usdc), 100, "gnoland-9");
        vm.warp(owed.timeoutTimestamp);
        router.timeoutPacket(IICS26RouterMsgs.MsgTimeoutPacket(owed, "", IICS02ClientMsgs.Height(0, 1)));
        assertEq(uint8(ctl.sendRecord("gnoland-9", owed.sequence).payment), uint8(T.Payment.Queued), "unpaid");
        assertEq(ctl.reserved(clientId, address(usdc)), 100);
        bytes32 implSlot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        bytes32 before = vm.load(address(ics20), implSlot);
        address stock = address(new ICS20Transfer());
        address controls =
            address(new GnoICS20Controls(address(new GnoICS20Reconcile(address(new GnoICS20Evidence())))));
        address older = address(new OlderFork(controls));
        address fork = address(new GnoICS20Transfer(controls));
        vm.expectRevert(T.GnoBadModule.selector);
        new GnoICS20Transfer(address(0));
        vm.expectRevert(T.GnoBadModule.selector);
        new GnoICS20Controls(address(0));
        // round 6 #2: a fork whose controls, or whose controls' reconciliation module, is not a module of its version
        address noControls = address(new GnoICS20Transfer(address(usdc)));
        address noReconcile = address(new GnoICS20Transfer(address(new GnoICS20Controls(address(usdc)))));
        uint64 toNoControls = _decide(S.KIND_UPGRADE, P.upgrade(address(ics20), noControls, noControls.codehash, ""));
        uint64 toNoReconcile = _decide(S.KIND_UPGRADE, P.upgrade(address(ics20), noReconcile, noReconcile.codehash, ""));
        uint64 toStock = _decide(S.KIND_UPGRADE, P.upgrade(address(ics20), stock, stock.codehash, ""));
        uint64 toOlder = _decide(S.KIND_UPGRADE, P.upgrade(address(ics20), older, older.codehash, ""));
        uint64 toFork = _decide(S.KIND_UPGRADE, P.upgrade(address(ics20), fork, fork.codehash, ""));
        _skip(7 days);
        admin.execute(toNoControls);
        admin.execute(toNoReconcile);
        assertEq(_state(toNoControls), S.SPENT, "missing controls");
        assertEq(_state(toNoReconcile), S.SPENT, "missing reconciliation");
        admin.execute(toStock);
        admin.execute(toOlder);
        assertEq(_state(toStock), S.SPENT);
        assertEq(_state(toOlder), S.SPENT);
        assertEq(vm.load(address(ics20), implSlot), before);
        admin.execute(toFork);
        assertEq(_state(toFork), S.EXECUTED);
        // the controls stand: the alias, the reservation and the queued refund
        assertEq(ctl.reserved("gnoland-9", address(usdc)), 100);
        for (uint256 i = 0; i < 20 && ctl.sendRecord("gnoland-9", owed.sequence).refunded < 100; i++) {
            _skip(1 days);
            ctl.claim("gnoland-9", address(usdc), 1);
        }
        assertEq(ctl.sendRecord("gnoland-9", owed.sequence).refunded, 100);
    }

    /// @notice Round 5 sweep (b): kind 6 stores a counterparty only in canonical form: gno.land's exact merkle
    /// prefix (spent at recording otherwise) and a well-formed client id; a verifier swap keeps the client's
    /// counterparty (spent at execution otherwise).
    function test_r5_b_kind6_canonicalCounterpartyOnly() public {
        MockLightClient x = new MockLightClient();
        bytes[] memory evil = _prefix();
        evil[1] = "/pv/vm:gno.land/r/evil/ibc/core:";
        bytes[] memory three = new bytes[](3);
        (three[0], three[1], three[2]) = ("main", "/pv/vm:gno.land/r/aib/ibc/core:", "x");
        bytes[] memory store = _prefix();
        store[0] = "acc";
        bytes[][3] memory bad = [evil, three, store];
        for (uint256 i = 0; i < 3; i++) {
            uint64 seq = admin.lastSeq() + 1;
            bytes memory params = P.client(1, "gnoland-5", "ethereum-5", bad[i], address(x), address(x).codehash);
            assertEq(_status(_recvGov(_env(seq, S.KIND_CLIENT, params))), S.STATUS_SPENT);
        }
        string[3] memory ids = ["", "Ethereum-5", "ethereum/5"];
        for (uint256 i = 0; i < 3; i++) {
            uint64 seq = admin.lastSeq() + 1;
            bytes memory params = P.client(1, "gnoland-5", ids[i], _prefix(), address(x), address(x).codehash);
            assertEq(_status(_recvGov(_env(seq, S.KIND_CLIENT, params))), S.STATUS_SPENT);
        }
        uint64 swap =
            _decide(S.KIND_CLIENT, P.client(2, clientId, "ethereum-5", _prefix(), address(x), address(x).codehash));
        uint64 add =
            _decide(S.KIND_CLIENT, P.client(1, "gnoland-5", "ethereum-5", _prefix(), address(x), address(x).codehash));
        _skip(7 days);
        admin.execute(swap);
        admin.execute(add);
        assertEq(_state(swap), S.SPENT, "a swap keeps the counterparty");
        assertEq(_state(add), S.EXECUTED);
    }

    /// @notice Kind 5 takes a gno.land base denom only in the exact form gno-realms' transfer app puts on the wire
    /// (a native denom, or a GRC20 alias as `GRC20Alias` makes it: gno-realms' TestGRC20AliasRoundTrip aliases are
    /// accepted); anything else is spent at recording.
    function test_r5_kind5_canonicalGnoDenomOnly() public {
        string[6] memory good = [
            "ugnot",
            "gno.land:r:demo:foo",
            "gno.land:r:demo:foo.FOO",
            "gno.land:r:demo:foo.Bar123",
            "gno.land:r:nt:grc20_v0:tok.T-1_x",
            "abcdefghijklmnop"
        ];
        for (uint256 i = 0; i < good.length; i++) {
            assertTrue(S.canonicalGnoDenom(good[i]), good[i]);
        }
        string[14] memory bad = [
            "",
            "ug",
            "Ugnot",
            "1gnot",
            "u gnot",
            "u_gnot",
            "ibc/ABC123",
            "transfer/client-0/ugnot",
            "gno.land/r/demo/foo.FOO",
            "gno.land:p:demo:foo.FOO",
            "gno.land:r:demo:foo.",
            "gno.land:r:Demo:foo.FOO",
            "gno.land:r:demo::foo.FOO",
            "gno.land:r:demo:foo.FO O"
        ];
        for (uint256 i = 0; i < bad.length; i++) {
            assertFalse(S.canonicalGnoDenom(bad[i]), bad[i]);
        }
        for (uint256 i = 0; i < 3; i++) {
            uint64 seq = admin.lastSeq() + 1;
            bytes memory params = P.voucher(clientId, bad[i + 6], address(0x4444), bytes32(uint256(1)));
            assertEq(_status(_recvGov(_env(seq, S.KIND_VOUCHER, params))), S.STATUS_SPENT, bad[i + 6]);
        }
        uint64 ok = admin.lastSeq() + 1;
        assertEq(
            _status(
                _recvGov(_env(ok, S.KIND_VOUCHER, P.voucher(clientId, "gno.land:r:demo:foo.FOO", address(0x4444), 0)))
            ),
            S.STATUS_RECORDED
        );
    }

    // ====================================================================================== round 6 ==

    /// @notice Round 6 #6: sends are capped at 2^96 - 1 (as receives), so the reservation, refund and loss
    /// arithmetic never overflows; at the cap, a reserved refund is paid in installments and kind 12 pays its
    /// remainder.
    function test_r6_6_amountBoundary_reservationArithmetic() public {
        uint256 cap = type(uint96).max;
        ERC20Mock big = new ERC20Mock();
        big.mint(alice, type(uint256).max);
        vm.prank(alice);
        big.approve(address(ics20), type(uint256).max);
        _setLimits(address(big), 1000, 1000, 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("ICS20InvalidAmount(uint256)", cap + 1));
        ics20.sendTransfer(
            IICS20TransferMsgs.SendTransferMsg(
                address(big), cap + 1, GNO_SENDER, clientId, "transfer", uint64(_now() + 600), ""
            )
        );
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("ICS20InvalidAmount(uint256)", type(uint256).max));
        ics20.sendTransfer(
            IICS20TransferMsgs.SendTransferMsg(
                address(big), type(uint256).max, GNO_SENDER, clientId, "transfer", uint64(_now() + 600), ""
            )
        );
        IICS26RouterMsgs.Packet memory pkt = _send(alice, address(big), cap, clientId);
        assertEq(ctl.reserved(clientId, address(big)), cap);
        _timeout(pkt); // beyond the refund meter: queued, its whole amount reserved
        assertEq(ctl.reserved(clientId, address(big)), cap);
        _skip(1 days);
        ctl.claim(clientId, address(big), 1); // an installment of 1
        assertEq(ctl.sendRecord(clientId, pkt.sequence).refunded, 1);
        assertEq(ctl.reserved(clientId, address(big)), cap - 1);
        _retire();
        _proveRefundable(pkt);
        _settle(_item(pkt.sequence, 1, cap - 1));
        assertEq(ctl.reserved(clientId, address(big)), 0);
        assertEq(big.balanceOf(alice), type(uint256).max);
    }

    /// @notice Round 6 #4: kind 12 booking a loss after the reopening finished closes the route again at once; a
    /// new kind 13 accepts the loss and opens it (the live client's outstanding sends do not block it).
    function test_r6_4_lossAfterReopening_closesTheRouteAgain() public {
        _setLimits(address(usdc), 1000, 1000, 1000);
        IICS26RouterMsgs.Packet memory a = _send(alice, address(usdc), 10, clientId);
        IICS26RouterMsgs.Packet memory late = _send(alice, address(usdc), 20, clientId);
        _errorAck(a); // forged refunds, paid at once
        _errorAck(late);
        _retire();
        _proveDelivered(a);
        _proveDelivered(late);
        _settle(_item(a.sequence, 4, 10));
        vm.prank(address(admin));
        ctl.reopenRoute("gnoland-9");
        assertFalse(ctl.routeClosed(clientId));
        assertEq(ctl.acceptedDeficit(clientId, address(usdc)), 10);
        _send(alice, address(usdc), 5, "gnoland-9"); // the live client's outstanding send
        _settle(_item(late.sequence, 4, 20)); // a loss found after the reopening
        assertTrue(ctl.routeClosed(clientId), "closed again");
        assertEq(ctl.losses(clientId, address(usdc)), 30);
        assertEq(ctl.acceptedDeficit(clientId, address(usdc)), 10);
        assertTrue(_isErrorAck(_transferIn("gnoland-9", "ugnot", 1, bob)));
        vm.prank(address(admin));
        ctl.reopenRoute("gnoland-9");
        assertFalse(ctl.routeClosed(clientId));
        assertEq(ctl.acceptedDeficit(clientId, address(usdc)), 30);
    }

    /// @notice Round 6 #1: on each refund payment path (paid at once by the ack hook, by `claim`, by `claimParked`)
    /// the meter is charged before the token moves, and a token hook cannot execute a matured kind 4 that changes
    /// the limits mid-payment: IBCAdmin refuses while a transfer-app entry point runs (`Busy`), the decision pends,
    /// and the payment is metered in full.
    function test_r6_1_paymentHooks_cannotChangeLimitsMidPayment() public {
        for (uint8 path = 0; path < 3; path++) {
            _hookPath(path);
        }
    }

    function _hookPath(uint8 path) internal {
        HookToken h = new HookToken();
        h.mint(alice, 300);
        vm.prank(alice);
        h.approve(address(ics20), type(uint256).max);
        _setLimits(address(h), 1000, 1000, 100);
        uint64 seq = _decide(
            S.KIND_LIMITS,
            P.limits(clientId, address(h), 2000, 1000, 50, 0, 0) // loosens: waits 7 days
        );
        _skip(7 days);
        bytes memory exec = abi.encodeCall(IBCAdmin.execute, (seq));
        IICS26RouterMsgs.Packet memory pkt;
        if (path == 0) {
            pkt = _send(alice, address(h), 100, clientId);
            h.setHook(alice, address(admin), exec);
            _timeout(pkt); // paid at once
            assertEq(uint8(ctl.sendRecord(clientId, pkt.sequence).payment), uint8(T.Payment.Paid));
        } else if (path == 1) {
            _timeout(_send(alice, address(h), 100, clientId)); // the meter full
            pkt = _send(alice, address(h), 100, clientId);
            _timeout(pkt); // queued
            _skip(1 days);
            h.setHook(alice, address(admin), exec);
            ctl.claim(clientId, address(h), 1);
            assertEq(uint8(ctl.sendRecord(clientId, pkt.sequence).payment), uint8(T.Payment.Claimed));
        } else {
            pkt = _send(alice, address(h), 100, clientId);
            h.setBlocked(alice, true);
            _timeout(pkt); // the token refuses: parked, the meter given back
            assertEq(ctl.limits(clientId, address(h)).refundLevel, 0);
            h.setBlocked(alice, false);
            h.setHook(alice, address(admin), exec);
            assertEq(ctl.claimParked(clientId, pkt.sequence, 0), 100);
        }
        assertFalse(h.hookOk(), "IBCAdmin refused inside the payment");
        assertEq(bytes4(h.hookRet()), IIBCAdmin.Busy.selector);
        assertEq(_state(seq), S.PENDING);
        assertEq(ctl.limits(clientId, address(h)).refundLevel, 100, "metered in full");
        admin.execute(seq); // outside any payment it executes
        assertEq(_state(seq), S.EXECUTED);
        assertEq(ctl.limits(clientId, address(h)).limits.refundCap, 50);
    }

    /// @notice Round 6 #3: an eight-record kind 12 through IBCAdmin.execute whose token burns all the gas of every
    /// payment: each payment runs out of its own bounded gas and is parked; the batch executes (not spent) and every
    /// record is settled. A claimParked with gas to spare is not bounded.
    function test_r6_3_gasBurningToken_eightItemBatch_parksEachPayment() public {
        GasBurnToken b = new GasBurnToken();
        b.mint(alice, 800);
        vm.prank(alice);
        b.approve(address(ics20), type(uint256).max);
        _setLimits(address(b), 1000, 1000, 1000);
        P.SettleItem[] memory items = new P.SettleItem[](8);
        IICS26RouterMsgs.Packet[] memory pkts = new IICS26RouterMsgs.Packet[](8);
        for (uint256 i = 0; i < 8; i++) {
            pkts[i] = _send(alice, address(b), 100, clientId);
            items[i] = P.SettleItem(pkts[i].sequence, 1, 100);
        }
        _retire();
        for (uint256 i = 0; i < 8; i++) {
            _proveRefundable(pkts[i]);
        }
        b.setBurnFor(alice);
        uint64 seq = _decide(S.KIND_SETTLE, P.settle(clientId, items));
        _skip(7 days);
        admin.execute{ gas: 15_000_000 }(seq);
        assertEq(_state(seq), S.EXECUTED, "settled, not spent");
        for (uint256 i = 0; i < 8; i++) {
            T.SendRecord memory rec = ctl.sendRecord(clientId, pkts[i].sequence);
            assertEq(rec.settlement, 1);
            assertEq(uint8(rec.payment), uint8(T.Payment.Parked));
        }
        assertEq(ctl.reserved(clientId, address(b)), 800);
        // nine items never record
        P.SettleItem[] memory nine = new P.SettleItem[](9);
        for (uint256 i = 0; i < 9; i++) {
            nine[i] = P.SettleItem(uint64(i + 1), 1, 1);
        }
        uint64 next = admin.lastSeq() + 1;
        assertEq(_status(_recvGov(_env(next, S.KIND_SETTLE, P.settle("c", nine)))), S.STATUS_SPENT);
        b.setBurnFor(address(0));
        vm.prank(address(admin));
        ctl.reopenRoute("gnoland-9");
        assertEq(ctl.claimParked(clientId, pkts[0].sequence, 0), 100);
    }

    /// @notice Round 6 #5: every kind's deterministic failure at execution spends the decision (its own frame:
    /// a refused call, a revert or a reason), and it can never run later; only a caller starving the frame leaves it
    /// pending. Kind 6 migrating a client that does not exist yet is spent, and stays spent once the client exists.
    function test_r6_5_deterministicFailures_spendEveryKind() public {
        uint64[] memory seqs = new uint64[](11);
        uint256 n;
        // kind 3: a key that holds a seat by execution (the second decision runs first)
        IGuardians.SeatKey[] memory a = new IGuardians.SeatKey[](1);
        a[0] = IGuardians.SeatKey(0, makeAddr("k"));
        IGuardians.SeatKey[] memory b = new IGuardians.SeatKey[](1);
        b[0] = IGuardians.SeatKey(1, makeAddr("k"));
        seqs[n++] = _decide(S.KIND_SEATS, P.seats(a));
        uint64 seatFirst = _decide(S.KIND_SEATS, P.seats(b));
        // kind 4: a loosening a later tightening (applied at recording) supersedes
        _setLimits(address(usdc), 1000, 1000, 1000);
        seqs[n++] = _decide(S.KIND_LIMITS, P.limits(clientId, address(usdc), 2000, 1000, 1000, 0, 0));
        _decide(S.KIND_LIMITS, P.limits(clientId, address(usdc), 500, 1000, 1000, 0, 0));
        // kind 5: a voucher whose code is not the decision's
        seqs[n++] = _decide(S.KIND_VOUCHER, P.voucher(clientId, "ubar", address(usdc), bytes32(uint256(1))));
        // kind 6: migrating a client that does not exist
        MockLightClient x = new MockLightClient();
        uint64 ghost =
            _decide(S.KIND_CLIENT, P.client(2, "gnoland-6", "ethereum-6", _prefix(), address(x), address(x).codehash));
        seqs[n++] = ghost;
        // kind 7: a proxy that is none of the four
        address impl = address(new ICS26Router());
        seqs[n++] = _decide(S.KIND_UPGRADE, P.upgrade(address(usdc), impl, impl.codehash, ""));
        // kind 9: an executor bound elsewhere
        AllowingExec foreign = new AllowingExec(address(router), d.accessManager, address(usdc));
        seqs[n++] = _decide(S.KIND_HANDOVER, P.handover(address(foreign), address(foreign).codehash, ""));
        // kind 10: a client no kind 6 enrolled
        seqs[n++] = _decide(S.KIND_ROUTE, P.route(clientId, "gnoland-77", 0));
        // kind 11: a shortening a later lengthening (applied at recording) supersedes
        seqs[n++] = _decide(S.KIND_SETTINGS, P.settings(clientId, 1 days));
        _decide(S.KIND_SETTINGS, P.settings(clientId, 30 days));
        // kind 12: a settlement of a record of an id still in use (the call reverts)
        seqs[n++] = _decide(S.KIND_SETTLE, P.settle1(clientId, 1, 1, 1));
        // kind 13: reopening an open route (the call reverts)
        seqs[n++] = _decide(S.KIND_REOPEN, P.reopen(clientId));
        _skip(7 days);
        admin.execute(seatFirst);
        for (uint256 i = 0; i < n; i++) {
            admin.execute(seqs[i]);
            assertEq(_state(seqs[i]), S.SPENT, vm.toString(i));
            vm.expectRevert(abi.encodeWithSelector(IIBCAdmin.NotPending.selector, seqs[i]));
            admin.execute(seqs[i]);
        }
        // the client the failed kind 6 named now exists: the spent decision still never runs
        uint64 add = _decide(
            S.KIND_CLIENT, P.client(1, "gnoland-6", "ethereum-6", _prefix(), address(lc), address(lc).codehash)
        );
        _skip(7 days);
        admin.execute(add);
        assertEq(_state(add), S.EXECUTED);
        vm.expectRevert(abi.encodeWithSelector(IIBCAdmin.NotPending.selector, ghost));
        admin.execute(ghost);
        assertEq(address(router.getClient("gnoland-6")), address(lc));
    }

    /// @notice Round 6 #5: a caller sending less gas than a kind's frame needs leaves the decision pending.
    function test_r6_5_starvedCaller_leavesThePending() public {
        uint64 seq = _decide(S.KIND_REOPEN, P.reopen(clientId));
        _skip(7 days);
        (bool ok,) = address(admin).call{ gas: 1_000_000 }(abi.encodeCall(admin.execute, (seq)));
        assertFalse(ok);
        assertEq(_state(seq), S.PENDING);
        admin.execute(seq);
        assertEq(_state(seq), S.SPENT);
    }

    // ====================================================================================== round 7 ==

    /// @notice Round 7 #3: a token hook calling drain() while the transfer app is busy records nothing, so a
    /// buffered tightening (kind 4, applied at recording) is never spent by the locked setter; drained later, it
    /// applies. A delivery from inside the hook reverts whole (nothing written), its number not consumed.
    function test_r7_3_drainFromATokenHook_recordsNothing() public {
        _setLimits(address(usdc), 1000, 1000, 1000);
        uint64 first = admin.lastSeq() + 1;
        for (uint64 s = first + 1; s < first + 9; s++) {
            assertEq(_status(_recvGov(_env(s, S.KIND_UNPAUSE, P.unpause(1, clientId)))), S.STATUS_BUFFERED);
        }
        uint64 tight = first + 9;
        bytes memory tightening = P.limits(clientId, address(usdc), 500, 1000, 1000, 0, 0);
        assertEq(_status(_recvGov(_env(tight, S.KIND_LIMITS, tightening))), S.STATUS_BUFFERED);
        _recvGov(_env(first, S.KIND_UNPAUSE, P.unpause(1, clientId))); // records first and drains eight
        assertEq(admin.lastSeq(), tight - 1);
        HookToken h = new HookToken();
        h.mint(alice, 100);
        vm.prank(alice);
        h.approve(address(ics20), type(uint256).max);
        _setLimits(address(h), 1000, 1000, 1000);
        IICS26RouterMsgs.Packet memory pkt = _send(alice, address(h), 100, clientId);
        h.setHook(alice, address(admin), abi.encodeCall(IBCAdmin.drain, ()));
        _timeout(pkt); // the refund's transfer runs the hook
        assertTrue(h.hookOk());
        assertEq(abi.decode(h.hookRet(), (uint256)), 0, "nothing recorded");
        assertEq(admin.lastSeq(), tight - 1);
        assertEq(admin.drain(), 1);
        assertEq(admin.decision(admin.epoch(), tight).state, S.EXECUTED);
        assertEq(ctl.limits(clientId, address(usdc)).limits.maxPerMessage, 500);
    }

    /// @notice Round 7 #5: a sender whose callback needs more than the automatic 100,000 gas (it books six fresh
    /// slots) is notified by a caller-funded retry with a larger budget; a caller sending too little reverts.
    function test_r7_5_costlyCallback_retriedWithALargerBudget() public {
        SenderAdapter adapter = new SenderAdapter(IICS20Transfer(address(ics20)), IERC20(address(usdc)), bob);
        usdc.mint(address(adapter), 100);
        adapter.setCost(6);
        _setLimits(address(usdc), 1000, 1000, 1000);
        vm.recordLogs();
        adapter.send(100, clientId);
        IICS26RouterMsgs.Packet memory pkt = _sentPacket();
        _timeout(pkt); // paid at once; the automatic notification runs out of gas: kept
        assertEq(adapter.notices(), 0);
        bytes memory notice = _timeoutNotice(pkt);
        assertFalse(ctl.retryNotification(clientId, pkt.sequence, notice, 0));
        vm.expectRevert(T.GnoNotificationStarved.selector);
        ctl.retryNotification{ gas: 300_000 }(clientId, pkt.sequence, notice, 400_000);
        assertTrue(ctl.retryNotification(clientId, pkt.sequence, notice, 400_000));
        assertEq(adapter.notices(), 1);
        assertEq(usdc.balanceOf(bob), 100);
    }

    /// @notice Round 7 #6: a forged success ack whose notification failed is superseded when reconciliation proves
    /// the packet refundable and pays it: the stale success can never be delivered; the refund is, once.
    function test_r7_6_supersededSuccessNotification_neverDelivered() public {
        SenderAdapter adapter = new SenderAdapter(IICS20Transfer(address(ics20)), IERC20(address(usdc)), bob);
        usdc.mint(address(adapter), 100);
        _setLimits(address(usdc), 1000, 1000, 1000);
        vm.recordLogs();
        adapter.send(100, clientId);
        IICS26RouterMsgs.Packet memory pkt = _sentPacket();
        adapter.setRefuse(true);
        bytes memory ok = bytes("{\"result\":\"AQ==\"}");
        _ack(pkt, ok); // a forged success ack; its notification fails and is kept
        adapter.setRefuse(false);
        _retire();
        _proveRefundable(pkt);
        _settle(_item(pkt.sequence, 1, 100));
        bytes memory stale = abi.encodeCall(
            IIBCSenderCallbacks.onAckPacket,
            (
                true,
                IIBCAppCallbacks.OnAcknowledgementPacketCallback(
                    pkt.sourceClient, pkt.destClient, pkt.sequence, pkt.payloads[0], ok, address(this)
                )
            )
        );
        vm.expectRevert(abi.encodeWithSelector(T.GnoNoNotification.selector, clientId, pkt.sequence));
        ctl.retryNotification(clientId, pkt.sequence, stale, 0);
        assertTrue(ctl.notifySettled(pkt, "", 0)); // the refund, the record's terminal notification
        assertEq(adapter.notices(), 1);
        assertEq(adapter.successes(), 0);
        assertEq(usdc.balanceOf(bob), 100);
        vm.expectRevert(abi.encodeWithSelector(T.GnoNoNotification.selector, clientId, pkt.sequence));
        ctl.notifySettled(pkt, "", 0);
    }

    /// @notice Round 7 #7: an outstanding packet that was delivered, settled by action 3, notifies its sender of the
    /// success, with the ack proven for it, once.
    function test_r7_7_deliveredOutstandingPacket_notifiedOfSuccess() public {
        SenderAdapter adapter = new SenderAdapter(IICS20Transfer(address(ics20)), IERC20(address(usdc)), bob);
        usdc.mint(address(adapter), 100);
        _setLimits(address(usdc), 1000, 1000, 1000);
        vm.recordLogs();
        adapter.send(100, clientId);
        IICS26RouterMsgs.Packet memory pkt = _sentPacket();
        _retire();
        _proveDelivered(pkt);
        _settle(_item(pkt.sequence, 3, 0));
        vm.expectRevert(abi.encodeWithSelector(T.GnoNoNotification.selector, clientId, pkt.sequence));
        ctl.notifySettled(pkt, bytes("{\"result\":\"AA==\"}"), 0); // not the proven ack
        assertTrue(ctl.notifySettled(pkt, bytes("{\"result\":\"AQ==\"}"), 0));
        assertEq(adapter.successes(), 1);
        vm.expectRevert(abi.encodeWithSelector(T.GnoNoNotification.selector, clientId, pkt.sequence));
        ctl.notifySettled(pkt, bytes("{\"result\":\"AQ==\"}"), 0);
    }

    /// @notice Round 7 #2: a reopening for a late loss on a retired client never reaches the live client's records:
    /// a forged success ack the live client accepted is counted when that client is replaced in turn (suspectFrom 0),
    /// and the route reopens only once it is settled.
    function test_r7_2_lateLossReopening_keepsTheLiveClientsRecords() public {
        _setLimits(address(usdc), 1000, 1000, 1000);
        string memory usdcBack = string.concat("transfer/", CP, "/", Strings.toHexString(address(usdc)));
        IICS26RouterMsgs.Packet memory sent = _send(alice, address(usdc), 100, clientId);
        _ack(sent, bytes("{\"result\":\"AQ==\"}"));
        assertTrue(_isSuccessAck(_transferIn(clientId, usdcBack, 100, bob))); // a forged receive on client-0
        uint64 inbound = nextRecvSeq[keccak256(bytes(clientId))];
        _retire(); // client-0 -> gnoland-9
        vm.prank(address(admin));
        ctl.reopenRoute("gnoland-9");
        // gnoland-9 accepts a forged success ack of an undelivered packet
        IICS26RouterMsgs.Packet memory b = _send(alice, address(usdc), 50, "gnoland-9");
        _ack(b, bytes("{\"result\":\"AQ==\"}"));
        _settle(_item(inbound, 5, 100)); // a late loss on client-0 closes the route
        assertTrue(ctl.routeClosed(clientId));
        vm.prank(address(admin));
        ctl.reopenRoute("gnoland-9"); // the late loss accepted
        assertFalse(ctl.routeClosed(clientId));
        // gnoland-9 replaced in turn, its interval from block 0: the forged ack counts
        address lc8 = address(new MockLightClient());
        vm.startPrank(address(admin));
        router.addClient("gnoland-8", IICS02ClientMsgs.CounterpartyInfo("ethereum-8", _prefix()), lc8);
        ctl.migrateRoute("gnoland-9", "gnoland-8", 0);
        vm.stopPrank();
        (, uint64 open) = ctl.suspectRecords("gnoland-9");
        assertEq(open, 1);
        vm.prank(address(admin));
        vm.expectRevert(abi.encodeWithSelector(T.GnoIncidentsPending.selector, "gnoland-8", 1));
        ctl.reopenRoute("gnoland-8");
        _proveRefundable(b);
        vm.startPrank(address(admin));
        ctl.settleRecords("gnoland-9", _item(b.sequence, 1, 50));
        ctl.reopenRoute("gnoland-8");
        vm.stopPrank();
        assertFalse(ctl.routeClosed(clientId));
    }

    /// @notice Round 7 #4: acks and timeouts on the live client between a late-loss closure and its reopening count
    /// against no incident: kind 13 reopens.
    function test_r7_4_liveClientAcks_duringLateLossClosure() public {
        _setLimits(address(usdc), 1000, 1000, 1000);
        IICS26RouterMsgs.Packet memory late = _send(alice, address(usdc), 20, clientId);
        _errorAck(late); // a forged refund, paid at once
        _retire();
        _proveDelivered(late);
        vm.prank(address(admin));
        ctl.reopenRoute("gnoland-9");
        IICS26RouterMsgs.Packet memory ok = _send(alice, address(usdc), 5, "gnoland-9");
        IICS26RouterMsgs.Packet memory out = _send(alice, address(usdc), 5, "gnoland-9");
        _settle(_item(late.sequence, 4, 20)); // a late loss closes the route
        assertTrue(ctl.routeClosed(clientId));
        _ack(ok, bytes("{\"result\":\"AQ==\"}")); // the live client's success ack
        vm.warp(out.timeoutTimestamp);
        router.timeoutPacket(IICS26RouterMsgs.MsgTimeoutPacket(out, "", IICS02ClientMsgs.Height(0, 1)));
        (, uint64 open) = ctl.suspectRecords("gnoland-9");
        assertEq(open, 0, "the live client counts against no incident");
        vm.prank(address(admin));
        ctl.reopenRoute("gnoland-9");
        assertFalse(ctl.routeClosed(clientId));
    }

    // ====================================================================================== round 8 ==

    /// @notice Round 8 sweep (b): kind 13 and a replacement do constant work whatever the number of incidents (and
    /// records): twelve replacements while the route is closed, each with an open record to reconcile, then kind 13
    /// through IBCAdmin (its fixed frame and the 1M call budget) reopens; its gas does not grow with the incidents.
    function test_r8_b_constantWorkReopen_manyIncidents() public {
        _setLimits(address(usdc), 1000, 1000, 1000);
        IICS26RouterMsgs.Packet[] memory pkts = new IICS26RouterMsgs.Packet[](12);
        for (uint256 i = 0; i < 12; i++) {
            pkts[i] = _send(alice, address(usdc), 10, clientId);
        }
        string memory live = clientId;
        for (uint256 i = 0; i < 12; i++) {
            string memory next = string.concat("gnoland-", vm.toString(40 + i));
            vm.startPrank(address(admin));
            router.addClient(
                next, IICS02ClientMsgs.CounterpartyInfo("ethereum-9", _prefix()), address(new MockLightClient())
            );
            ctl.migrateRoute(live, next, 0); // the later ones while the route is closed
            vm.stopPrank();
            live = next;
        }
        (T.Incident[] memory inc,, uint64 pending) = ctl.incidents(clientId);
        assertEq(inc.length, 12);
        assertEq(pending, 1, "only client-0 has records to reconcile");
        for (uint256 i = 0; i < 12; i++) {
            _proveRefundable(pkts[i]);
        }
        vm.prank(address(admin));
        vm.expectRevert(abi.encodeWithSelector(T.GnoIncidentsPending.selector, live, 1));
        ctl.reopenRoute(live);
        for (uint256 i = 0; i < 12; i++) {
            _settle(_item(pkts[i].sequence, 1, 10));
        }
        (,, pending) = ctl.incidents(clientId);
        assertEq(pending, 0);
        uint64 seq = _decide(S.KIND_REOPEN, P.reopen(live));
        _skip(7 days);
        uint256 g = gasleft();
        admin.execute(seq);
        uint256 used = g - gasleft();
        assertEq(_state(seq), S.EXECUTED);
        assertFalse(ctl.routeClosed(clientId));
        (inc,,) = ctl.incidents(clientId);
        for (uint256 i = 0; i < 12; i++) {
            assertEq(inc[i].status, 3);
        }
        assertLt(used, 300_000, "constant work: no walk of the twelve incidents");
    }

    /// @notice Round 8 sweep (a): a loss has one canonical identity (client id, sequence, direction): a send's forged
    /// refund and a forged receive at the same sequence number are two packets, each booked once; neither is booked
    /// again under any path, late ones included.
    function test_r8_a_lossIdentity_oncePerPacketAndDirection() public {
        _setLimits(address(usdc), 1000, 1000, 1000);
        string memory usdcBack = string.concat("transfer/", CP, "/", Strings.toHexString(address(usdc)));
        IICS26RouterMsgs.Packet memory out = _send(alice, address(usdc), 30, clientId);
        IICS26RouterMsgs.Packet memory base = _send(alice, address(usdc), 50, clientId);
        _ack(base, bytes("{\"result\":\"AQ==\"}")); // delivered: backing for the receive
        _errorAck(out); // a forged refund, paid
        assertTrue(_isSuccessAck(_transferIn(clientId, usdcBack, 20, bob))); // a forged receive
        uint64 inbound = nextRecvSeq[keccak256(bytes(clientId))];
        assertEq(inbound, out.sequence, "the same number, two directions");
        _retire();
        _proveDelivered(out);
        _proveDelivered(base);
        _settle(_item(base.sequence, 3, 0));
        _settle(_item(out.sequence, 4, 30));
        assertTrue(ctl.lossBooked(clientId, out.sequence, 1));
        assertFalse(ctl.lossBooked(clientId, inbound, 2));
        vm.prank(address(admin));
        ctl.reopenRoute("gnoland-9");
        _settle(_item(inbound, 5, 20)); // a late loss, the other direction
        assertTrue(ctl.lossBooked(clientId, inbound, 2));
        assertEq(ctl.losses(clientId, address(usdc)), 50);
        vm.startPrank(address(admin));
        vm.expectRevert(abi.encodeWithSelector(T.GnoBadSettlement.selector, 0));
        ctl.settleRecords(clientId, _item(out.sequence, 4, 30));
        vm.expectRevert(abi.encodeWithSelector(T.GnoBadSettlement.selector, 0));
        ctl.settleRecords(clientId, _item(inbound, 5, 20));
        vm.stopPrank();
        assertEq(ctl.losses(clientId, address(usdc)), 50);
    }

    /// @notice Round 8 #1: kind 10 checks, immediately before retiring the old route and switching the epoch, that
    /// the replacement's verifier is for gno.land's chain and neither frozen nor expired (recovery disabled here):
    /// a replacement whose client froze or expired during the delay is spent, the old route untouched.
    function test_r8_1_replacementToABadVerifier_spent_frozen() public {
        _badReplacement(1);
    }

    function test_r8_1_replacementToABadVerifier_spent_expired() public {
        _badReplacement(2);
    }

    function test_r8_1_replacementToABadVerifier_spent_otherChain() public {
        _badReplacement(3);
    }

    function _badReplacement(uint8 how) internal {
        assertEq(admin.recoveryConfig().delay, 0, "recovery disabled");
        MockLightClient lc2 = new MockLightClient();
        uint64 add = _decide(
            S.KIND_CLIENT, P.client(1, "gnoland-2", "ethereum-2", _prefix(), address(lc2), address(lc2).codehash)
        );
        uint64 replace = _decide(S.KIND_ROUTE, P.route(clientId, "gnoland-2", 0));
        _skip(7 days);
        admin.execute(add);
        assertEq(_state(add), S.EXECUTED);
        if (how == 1) lc2.setStatus(true, false);
        else if (how == 2) lc2.setStatus(false, true);
        else lc2.setChainId("other-chain");
        admin.execute(replace);
        assertEq(_state(replace), S.SPENT);
        assertEq(admin.epoch(), 1);
        assertEq(admin.govClient(), clientId);
        assertFalse(ctl.isRetired(clientId));
        assertFalse(ctl.routeClosed(clientId));
        assertTrue(_isSuccessAck(_gnotIn(1, bob)), "the old route works");
    }

    /// @notice Round 8 #1 sweep: kind 6 installs no verifier that is frozen, expired or for another chain, by
    /// addition or by migration.
    function test_r8_1_kind6_installsOnlyUsableVerifiers() public {
        MockLightClient frozen = new MockLightClient();
        frozen.setStatus(true, false);
        MockLightClient expired = new MockLightClient();
        expired.setStatus(false, true);
        MockLightClient other = new MockLightClient();
        other.setChainId("other-chain");
        MockLightClient[3] memory bad = [frozen, expired, other];
        uint64[6] memory seqs;
        for (uint256 i = 0; i < 3; i++) {
            address a = address(bad[i]);
            seqs[2 * i] = _decide(
                S.KIND_CLIENT,
                P.client(1, string.concat("gnoland-", vm.toString(60 + i)), "ethereum-6", _prefix(), a, a.codehash)
            );
            seqs[2 * i + 1] = _decide(S.KIND_CLIENT, P.client(2, clientId, CP, _prefix(), a, a.codehash));
        }
        _skip(7 days);
        address before = address(router.getClient(clientId));
        for (uint256 i = 0; i < 6; i++) {
            admin.execute(seqs[i]);
            assertEq(_state(seqs[i]), S.SPENT, vm.toString(i));
        }
        assertEq(address(router.getClient(clientId)), before);
    }

    /// @notice Round 8 #3: 512 incidents (replacements while the route is closed), all reconciled; kind 13 through
    /// IBCAdmin.execute (its fixed frame and 1M call budget) reopens, walking none of them.
    function test_r8_3_reopen_512Incidents_throughIBCAdmin() public {
        string memory live = clientId;
        address lcx = address(new MockLightClient());
        vm.startPrank(address(admin));
        for (uint256 i = 0; i < 512; i++) {
            string memory next = string.concat("gnoland-", vm.toString(1000 + i));
            router.addClient(next, IICS02ClientMsgs.CounterpartyInfo("ethereum-9", _prefix()), lcx);
            ctl.migrateRoute(live, next, 0);
            live = next;
        }
        vm.stopPrank();
        (T.Incident[] memory inc, uint64 resolved, uint64 pending) = ctl.incidents(clientId);
        assertEq(inc.length, 512);
        assertEq(resolved, 0);
        assertEq(pending, 0);
        uint64 seq = _decide(S.KIND_REOPEN, P.reopen(live));
        _skip(7 days);
        admin.execute(seq);
        assertEq(_state(seq), S.EXECUTED);
        assertFalse(ctl.routeClosed(clientId));
        (inc, resolved,) = ctl.incidents(clientId);
        assertEq(resolved, 512);
        assertEq(inc[511].status, 3);
    }

    /// @notice Round 8 #2: a token whose balanceOf needs more than the automatic 30,000 gas: its refund parks at
    /// the timeout and after reconciliation (automatic processing stays bounded); a caller-funded claimParked with a
    /// larger budget pays both; too little gas sent for the budget reverts as starved.
    function test_r8_2_costlyBalanceOf_paidByABudgetedRetry() public {
        CostlyBalanceToken c = new CostlyBalanceToken();
        c.mint(alice, 300);
        vm.prank(alice);
        c.approve(address(ics20), type(uint256).max);
        _setLimits(address(c), 1000, 1000, 1000);
        IICS26RouterMsgs.Packet memory a = _send(alice, address(c), 100, clientId);
        IICS26RouterMsgs.Packet memory b = _send(alice, address(c), 100, clientId);
        _timeout(a); // the balance read runs out of its bound: parked
        assertEq(uint8(ctl.sendRecord(clientId, a.sequence).payment), uint8(T.Payment.Parked));
        vm.expectRevert(abi.encodeWithSelector(T.GnoRefundFailed.selector, clientId, a.sequence));
        ctl.claimParked(clientId, a.sequence, 0);
        vm.expectRevert(T.GnoPaymentStarved.selector);
        ctl.claimParked{ gas: 400_000 }(clientId, a.sequence, 300_000);
        assertEq(ctl.claimParked(clientId, a.sequence, 300_000), 100);
        _retire();
        _proveRefundable(b);
        _settle(_item(b.sequence, 1, 100)); // kind 12's payment is bounded too: parked
        assertEq(uint8(ctl.sendRecord(clientId, b.sequence).payment), uint8(T.Payment.Parked));
        vm.prank(address(admin));
        ctl.reopenRoute("gnoland-9");
        assertEq(ctl.claimParked(clientId, b.sequence, 300_000), 100);
        assertEq(c.balanceOf(alice), 300);
    }

    // ====================================================================================== round 9 ==

    function _statusSelectors() internal pure returns (bytes4[3] memory) {
        return
            [bytes4(keccak256("isFrozen()")), bytes4(keccak256("isExpired()")), bytes4(keccak256("lastTransition()"))];
    }

    /// @notice Round 9 #1: kind 6 installs no verifier whose status views (frozen, expired, last transition) are
    /// missing, revert, return short, or return an out-of-range value: every case is unusable (fail closed).
    function test_r9_1_kind6_statusViewsFailClosed() public {
        bytes4[3] memory sels = _statusSelectors();
        uint64[] memory seqs = new uint64[](12);
        uint256 n;
        for (uint256 i = 0; i < 3; i++) {
            for (uint8 m = 1; m <= 4; m++) {
                StatusMock c = new StatusMock();
                c.setMode(sels[i], m);
                seqs[n++] = _decide(
                    S.KIND_CLIENT,
                    P.client(
                        1,
                        string.concat("gnoland-", vm.toString(70 + n)),
                        "ethereum-7",
                        _prefix(),
                        address(c),
                        address(c).codehash
                    )
                );
            }
        }
        StatusMock healthy = new StatusMock();
        uint64 good = _decide(
            S.KIND_CLIENT,
            P.client(1, "gnoland-99", "ethereum-7", _prefix(), address(healthy), address(healthy).codehash)
        );
        _skip(7 days);
        for (uint256 i = 0; i < n; i++) {
            admin.execute(seqs[i]);
            assertEq(_state(seqs[i]), S.SPENT, vm.toString(i));
        }
        admin.execute(good);
        assertEq(_state(good), S.EXECUTED, "a client answering exactly is installed");
    }

    /// @notice Round 9 #1: kind 10 to a client whose status views stopped answering exactly since kind 6 enrolled
    /// it is spent, the old route untouched (recovery disabled).
    function test_r9_1_kind10_statusViewsFailClosed() public {
        bytes4[3] memory sels = _statusSelectors();
        uint256 n;
        for (uint256 i = 0; i < 3; i++) {
            for (uint8 m = 1; m <= 4; m++) {
                StatusMock c = new StatusMock();
                string memory id = string.concat("gnoland-", vm.toString(80 + n++));
                uint64 add =
                    _decide(S.KIND_CLIENT, P.client(1, id, "ethereum-8", _prefix(), address(c), address(c).codehash));
                uint64 replace = _decide(S.KIND_ROUTE, P.route(clientId, id, 0));
                _skip(7 days);
                admin.execute(add);
                assertEq(_state(add), S.EXECUTED);
                c.setMode(sels[i], m);
                admin.execute(replace);
                assertEq(_state(replace), S.SPENT, vm.toString(n));
                assertEq(admin.govClient(), clientId);
                assertFalse(ctl.isRetired(clientId));
            }
        }
    }

    // ====================================================================================== round 10 ==

    /// @notice Round 10 (a): kind 12 checks each payment against the batch's complete reservations: a rejection in
    /// the same batch frees its reservation before the refund is paid, in either item order (tight escrow).
    function test_r10_a_tightEscrow_mixedBatch_bothOrders() public {
        _setLimits(address(usdc), 1000, 1000, 1);
        IICS26RouterMsgs.Packet memory a = _send(alice, address(usdc), 100, clientId); // never delivered
        IICS26RouterMsgs.Packet memory b = _send(alice, address(usdc), 100, clientId); // delivered
        _errorAck(b); // a forged error ack: queued under the 1-unit meter, reserved
        address escrow = ics20.getEscrow(clientId);
        vm.prank(escrow);
        usdc.transfer(address(0xdead), 100); // an incident: escrow 100 for 200 reserved
        _retire();
        _proveRefundable(a);
        _proveDelivered(b);
        T.SettleItem[] memory ab = new T.SettleItem[](2);
        ab[0] = T.SettleItem(a.sequence, 1, 100);
        ab[1] = T.SettleItem(b.sequence, 2, 0);
        T.SettleItem[] memory ba = new T.SettleItem[](2);
        ba[0] = T.SettleItem(b.sequence, 2, 0);
        ba[1] = T.SettleItem(a.sequence, 1, 100);
        uint256 snap = vm.snapshotState();
        uint256 before = usdc.balanceOf(alice);
        _settle(ab);
        assertEq(usdc.balanceOf(alice), before + 100, "paid with the payment first");
        assertEq(uint8(ctl.sendRecord(clientId, a.sequence).payment), uint8(T.Payment.Claimed));
        vm.revertToState(snap);
        _settle(ba);
        assertEq(usdc.balanceOf(alice), before + 100, "paid with the rejection first");
    }

    /// @notice Round 10 (b): a receive whose packet data does not decode is refused with a custom error (an error
    /// ack), never an empty revert that would make the relayer's whole transaction fail.
    function test_r10_b_undecodableReceive_errorAck() public {
        IICS26RouterMsgs.Packet memory pkt = _packetFromGno(
            clientId, ICS20Lib.DEFAULT_PORT_ID, ICS20Lib.ICS20_VERSION, ICS20Lib.ICS20_ENCODING, hex"deadbeef"
        );
        assertTrue(_isErrorAck(_recv(pkt)));
    }

    /// @notice Round 10 (b): a returning token whose transfer reverts with no data is an error ack too.
    function test_r10_b_tokenRevertingEmpty_errorAck() public {
        MuteRevertToken m = new MuteRevertToken();
        m.mint(alice, 100);
        vm.prank(alice);
        m.approve(address(ics20), type(uint256).max);
        _setLimits(address(m), 1000, 1000, 1000);
        IICS26RouterMsgs.Packet memory out = _send(alice, address(m), 100, clientId);
        _ack(out, bytes("{\"result\":\"AQ==\"}"));
        m.setMute(bob);
        string memory back = string.concat("transfer/", CP, "/", Strings.toHexString(address(m)));
        assertTrue(_isErrorAck(_transferIn(clientId, back, 10, bob)));
        m.setMute(address(0));
        assertTrue(_isSuccessAck(_transferIn(clientId, back, 10, bob)));
    }

    IICS26RouterMsgs.Packet[] internal _later;

    function _retireLater(IICS26RouterMsgs.Packet memory pkt) internal {
        _later.push(pkt);
    }

    // ============================================================== #20 send variants and reentrancy ==

    function test_r20_permit2Send_isControlledAndRecorded() public {
        _setLimits(clientId, address(usdc), T.Limits(1000, 1000, 1000, 100, 10));
        address permit2 = ics20.getPermit2();
        vm.prank(alice);
        usdc.approve(permit2, type(uint256).max);
        ISignatureTransfer.PermitTransferFrom memory permit =
            ISignatureTransfer.PermitTransferFrom(ISignatureTransfer.TokenPermissions(address(usdc), 101), 0, 0);
        IICS20TransferMsgs.SendTransferMsg memory m = IICS20TransferMsgs.SendTransferMsg({
            denom: address(usdc),
            amount: 101,
            receiver: GNO_SENDER,
            sourceClient: clientId,
            destPort: ICS20Lib.DEFAULT_PORT_ID,
            timeoutTimestamp: uint64(_now() + 600),
            memo: ""
        });
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(T.GnoSendAboveMax.selector, address(usdc), 101, 100));
        ics20.sendTransferWithPermit2(m, permit, "");
        m.amount = 50;
        vm.prank(alice);
        uint64 seq = ics20.sendTransferWithPermit2(m, permit, "");
        T.SendRecord memory rec = ctl.sendRecord(clientId, seq);
        assertEq(rec.sender, alice);
        assertEq(rec.amount, 50);
        assertTrue(rec.commitment != bytes32(0));
    }

    function test_r20_sendWithSender_refundsTheNamedSender() public {
        _setLimits(address(usdc), 1000, 1000, 1000);
        vm.prank(address(admin));
        IAccessManager(d.accessManager).grantRole(IBCRolesLib.DELEGATE_SENDER_ROLE, alice, 0);
        IICS20TransferMsgs.SendTransferMsg memory m = IICS20TransferMsgs.SendTransferMsg({
            denom: address(usdc),
            amount: 70,
            receiver: GNO_SENDER,
            sourceClient: clientId,
            destPort: ICS20Lib.DEFAULT_PORT_ID,
            timeoutTimestamp: uint64(_now() + 600),
            memo: ""
        });
        vm.recordLogs();
        vm.prank(alice);
        uint64 seq = ics20.sendTransferWithSender(m, bob);
        assertEq(ctl.sendRecord(clientId, seq).sender, bob);
        _errorAck(_sentPacket());
        assertEq(usdc.balanceOf(bob), 70);
    }

    function test_r20_reentrantClaim_duringAPayment_neverPaysTwice() public {
        ReentrantToken tok = new ReentrantToken();
        tok.mint(alice, 1000);
        vm.prank(alice);
        tok.approve(address(ics20), type(uint256).max);
        _setLimits(address(tok), 1000, 1000, 1000);
        IICS26RouterMsgs.Packet memory a = _send(alice, address(tok), 100, clientId);
        IICS26RouterMsgs.Packet memory b = _send(alice, address(tok), 100, clientId);
        _setLimits(address(tok), 1000, 1000, 100); // room for one refund now
        _errorAck(a); // paid at once
        _errorAck(b); // queued
        tok.arm(ctl, clientId, alice);
        _skip(1 days);
        ctl.claim(clientId, address(tok), 5); // paying alice re-enters claim, which the shared lock refuses
        assertTrue(tok.reentryRefused());
        assertEq(tok.balanceOf(alice), 1000, "each refund paid exactly once");
        assertEq(ctl.sendRecord(clientId, b.sequence).refunded, 100);
    }

    // ================================================================================================ round 11 ==

    /// @notice r11 #1: a conflict after an unpause was recorded survives that unpause (the conflict block is
    /// refreshed on every conflict, not kept from the first one), so 7-day decisions stay deferred.
    function test_r11_1_laterConflict_survivesAnOlderUnpause() public {
        _recvGov(_env(1, S.KIND_SETTINGS, P.settings(clientId, 1)));
        _recvGov(_env(1, S.KIND_SETTINGS, P.settings(clientId, 2))); // conflict A
        _skip(12);
        _recvGov(_env(2, S.KIND_UNPAUSE, P.unpause(2, "")));
        uint64 recorded = admin.decision(admin.epoch(), 2).recordedBlock;
        _skip(12);
        _recvGov(_env(1, S.KIND_SETTINGS, P.settings(clientId, 3))); // conflict B, after the unpause's recording
        assertGt(admin.conflictBlock(), recorded, "refreshed by the later conflict");
        _skip(1 days);
        admin.execute(2);
        assertEq(admin.decision(admin.epoch(), 2).state, S.EXECUTED);
        assertGt(admin.conflictBlock(), 0, "the later conflict stands");
        _skip(7 days);
        vm.expectRevert(IIBCAdmin.Deferred.selector);
        admin.execute(1);
    }

    function _ackNotice(
        IICS26RouterMsgs.Packet memory pkt,
        bytes memory ack,
        address relayer
    )
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeCall(
            IIBCSenderCallbacks.onAckPacket,
            (
                true,
                IIBCAppCallbacks.OnAcknowledgementPacketCallback(
                    pkt.sourceClient, pkt.destClient, pkt.sequence, pkt.payloads[0], ack, relayer
                )
            )
        );
    }

    /// @notice r11 #2: a forged success ack A of a delivered packet, whose notification the sender refused, is
    /// replaced by the proven success ack B once action 3 settles it: A can no longer be retried, B is delivered,
    /// exactly once.
    function test_r11_2_provenSuccessAck_replacesAForgedOne() public {
        SenderAdapter adapter = new SenderAdapter(IICS20Transfer(address(ics20)), IERC20(address(usdc)), bob);
        usdc.mint(address(adapter), 100);
        _setLimits(address(usdc), 1000, 1000, 1000);
        vm.recordLogs();
        adapter.send(100, clientId);
        IICS26RouterMsgs.Packet memory pkt = _sentPacket();
        bytes memory forged = bytes("{\"result\":\"Zm9yZ2Vk\"}");
        bytes memory proven = bytes("{\"result\":\"AQ==\"}");
        adapter.setRefuse(true);
        _ack(pkt, forged); // A: accepted by the compromised verifier; its notification fails and is kept
        adapter.setRefuse(false);
        assertEq(adapter.successes(), 0);
        _retire();
        _proveDelivered(pkt); // B
        _settle(_item(pkt.sequence, 3, 0));
        // A is never announced once B is proven
        vm.expectRevert(abi.encodeWithSelector(T.GnoNoNotification.selector, clientId, pkt.sequence));
        ctl.retryNotification(clientId, pkt.sequence, _ackNotice(pkt, forged, address(this)), 0);
        // nor any ack but the proven one
        vm.expectRevert(abi.encodeWithSelector(T.GnoNoNotification.selector, clientId, pkt.sequence));
        ctl.notifySettled(pkt, forged, 0);
        // B: a failed attempt keeps it, then it is delivered once
        adapter.setRefuse(true);
        assertFalse(ctl.notifySettled(pkt, proven, 0));
        adapter.setRefuse(false);
        assertTrue(ctl.notifySettled(pkt, proven, 0));
        assertEq(adapter.successes(), 1);
        assertEq(adapter.lastAck(), keccak256(proven));
        vm.expectRevert(abi.encodeWithSelector(T.GnoNoNotification.selector, clientId, pkt.sequence));
        ctl.notifySettled(pkt, proven, 0);
        vm.expectRevert(abi.encodeWithSelector(T.GnoNoNotification.selector, clientId, pkt.sequence));
        ctl.retryNotification(clientId, pkt.sequence, _ackNotice(pkt, forged, address(this)), 0);
        assertEq(adapter.successes(), 1);
    }

    /// @notice r11 #2, the other order: the transport's success notification, retried after action 3 proved the same
    /// ack, is delivered once; a settled notification of it after that is refused.
    function test_r11_2_sameAck_retriedOnce() public {
        SenderAdapter adapter = new SenderAdapter(IICS20Transfer(address(ics20)), IERC20(address(usdc)), bob);
        usdc.mint(address(adapter), 100);
        _setLimits(address(usdc), 1000, 1000, 1000);
        vm.recordLogs();
        adapter.send(100, clientId);
        IICS26RouterMsgs.Packet memory pkt = _sentPacket();
        bytes memory ok = bytes("{\"result\":\"AQ==\"}");
        adapter.setRefuse(true);
        _ack(pkt, ok);
        adapter.setRefuse(false);
        _retire();
        _proveDelivered(pkt);
        _settle(_item(pkt.sequence, 3, 0));
        assertTrue(ctl.retryNotification(clientId, pkt.sequence, _ackNotice(pkt, ok, address(this)), 0));
        assertEq(adapter.successes(), 1);
        vm.expectRevert(abi.encodeWithSelector(T.GnoNoNotification.selector, clientId, pkt.sequence));
        ctl.notifySettled(pkt, ok, 0);
        assertEq(adapter.successes(), 1);
    }

    /// @notice r11 #2: the same ack delivered through `notifySettled` first; the transport's kept notification is
    /// then done and never retried.
    function test_r11_2_sameAck_settledFirst_neverRetried() public {
        SenderAdapter adapter = new SenderAdapter(IICS20Transfer(address(ics20)), IERC20(address(usdc)), bob);
        usdc.mint(address(adapter), 100);
        _setLimits(address(usdc), 1000, 1000, 1000);
        vm.recordLogs();
        adapter.send(100, clientId);
        IICS26RouterMsgs.Packet memory pkt = _sentPacket();
        bytes memory ok = bytes("{\"result\":\"AQ==\"}");
        adapter.setRefuse(true);
        _ack(pkt, ok);
        adapter.setRefuse(false);
        _retire();
        _proveDelivered(pkt);
        _settle(_item(pkt.sequence, 3, 0));
        assertTrue(ctl.notifySettled(pkt, ok, 0));
        vm.expectRevert(abi.encodeWithSelector(T.GnoNoNotification.selector, clientId, pkt.sequence));
        ctl.retryNotification(clientId, pkt.sequence, _ackNotice(pkt, ok, address(this)), 0);
        assertEq(adapter.successes(), 1);
    }

    // ============================================================================================= round 17 ==

    /// @notice r17 #1: two undelivered sends of 100 get forged success acks (their reservations released); a forged
    /// receive leaves 150 in escrow. One kind 12 owes both refunds again: both are reserved before either is paid,
    /// so the first payment (100) would leave the second's 100 short and is refused; both stay parked, fully
    /// reserved, in either item order.
    function _twinHidden(bool reversed) internal {
        _setLimits(address(usdc), 1000, 1000, 1000);
        IICS26RouterMsgs.Packet memory a = _send(alice, address(usdc), 100, clientId);
        IICS26RouterMsgs.Packet memory b = _send(alice, address(usdc), 100, clientId);
        _ack(a, bytes("{\"result\":\"AQ==\"}"));
        _ack(b, bytes("{\"result\":\"AQ==\"}")); // forged success acks
        assertEq(ctl.reserved(clientId, address(usdc)), 0);
        _transferIn(clientId, string.concat("transfer/", CP, "/", Strings.toHexString(address(usdc))), 50, bob);
        address escrow = ics20.getEscrow(clientId);
        assertEq(usdc.balanceOf(escrow), 150);
        _retire();
        _proveRefundable(a);
        _proveRefundable(b);
        T.SettleItem[] memory items = new T.SettleItem[](2);
        items[reversed ? 1 : 0] = T.SettleItem(a.sequence, 1, 100);
        items[reversed ? 0 : 1] = T.SettleItem(b.sequence, 1, 100);
        vm.prank(address(admin));
        ctl.settleRecords(clientId, items);
        // neither paid: either payment would have taken the other's backing
        assertEq(usdc.balanceOf(escrow), 150);
        assertEq(ctl.reserved(clientId, address(usdc)), 200);
        assertEq(uint8(ctl.sendRecord(clientId, a.sequence).payment), uint8(T.Payment.Parked));
        assertEq(uint8(ctl.sendRecord(clientId, b.sequence).payment), uint8(T.Payment.Parked));
    }

    function test_r17_1_twinHiddenRefunds_reservedBeforeAnyPayment() public {
        _twinHidden(false);
    }

    function test_r17_1_twinHiddenRefunds_reservedBeforeAnyPayment_reversed() public {
        _twinHidden(true);
    }

    /// @notice r17 #2: an enabled recovery's public delay is at least 30 days (`MIN_RECOVERY_DELAY`); zero disables
    /// it.
    function test_r17_2_recoveryDelay_atLeast30Days() public {
        _adminWith(0, 3, 3); // disabled
        vm.expectRevert(IIBCAdmin.RecoveryState.selector);
        _adminWith(1, 3, 3);
        vm.expectRevert(IIBCAdmin.RecoveryState.selector);
        _adminWith(30 days - 1, 3, 3);
        _adminWith(30 days, 3, 3);
    }

    // ============================================================================================= round 18 ==

    /// @notice `n` undelivered sends of `each` with forged success acks (reservations released), then a forged receive
    /// leaving `left` in escrow; retired and each proven refundable. Returns the packets.
    function _hiddenRefunds(
        uint256 n,
        uint256 each,
        uint256 left
    )
        internal
        returns (IICS26RouterMsgs.Packet[] memory pkts)
    {
        _setLimits(address(usdc), 1e9, 1e9, 1e9);
        pkts = new IICS26RouterMsgs.Packet[](n);
        for (uint256 i = 0; i < n; i++) {
            pkts[i] = _send(alice, address(usdc), each, clientId);
            _ack(pkts[i], bytes("{\"result\":\"AQ==\"}"));
        }
        assertEq(ctl.reserved(clientId, address(usdc)), 0);
        _transferIn(
            clientId, string.concat("transfer/", CP, "/", Strings.toHexString(address(usdc))), n * each - left, bob
        );
        _retire();
        for (uint256 i = 0; i < n; i++) {
            _proveRefundable(pkts[i]);
        }
    }

    /// @notice r18 #1: a proven refundable outcome of a hidden refund reserves it at once, so settling the refunds in
    /// SEPARATE decisions still never lets one take the other's backing: 150 against 200, the first decision pays
    /// nothing, nor does the second.
    function test_r18_1_hiddenRefunds_separateDecisions() public {
        IICS26RouterMsgs.Packet[] memory p = _hiddenRefunds(2, 100, 150);
        assertEq(ctl.reserved(clientId, address(usdc)), 200, "reserved from the proof");
        address escrow = ics20.getEscrow(clientId);
        _settle(_item(p[0].sequence, 1, 100));
        assertEq(ctl.sendRecord(clientId, p[0].sequence).refunded, 0, "the first decision pays nothing");
        _settle(_item(p[1].sequence, 1, 100));
        assertEq(ctl.sendRecord(clientId, p[1].sequence).refunded, 0);
        assertEq(usdc.balanceOf(escrow), 150);
        assertEq(ctl.reserved(clientId, address(usdc)), 200);
    }

    /// @notice r18 #1, the eight-item boundary: nine hidden refunds of 10 against 80. The first decision settles the
    /// most a kind 12 takes, eight: with the ninth reserved since its proof, none of the eight may pay (each would
    /// leave the others short). The ninth, settled alone, parks too.
    function test_r18_1_hiddenRefunds_eightItemBoundary() public {
        IICS26RouterMsgs.Packet[] memory p = _hiddenRefunds(9, 10, 80);
        assertEq(ctl.reserved(clientId, address(usdc)), 90);
        T.SettleItem[] memory items = new T.SettleItem[](8);
        for (uint256 i = 0; i < 8; i++) {
            items[i] = T.SettleItem(p[i].sequence, 1, 10);
        }
        _settle(items);
        for (uint256 i = 0; i < 8; i++) {
            assertEq(ctl.sendRecord(clientId, p[i].sequence).refunded, 0);
        }
        _settle(_item(p[8].sequence, 1, 10));
        assertEq(ctl.sendRecord(clientId, p[8].sequence).refunded, 0);
        assertEq(usdc.balanceOf(ics20.getEscrow(clientId)), 80);
        assertEq(ctl.reserved(clientId, address(usdc)), 90);
    }

    /// @notice r19 #1: an outcome its verifier no longer vouches for is voided by anyone so it can be proven again;
    /// the hidden refund's liability and reservation stay. Since round 20 no proof releases it, not even one of
    /// delivery: only the kind 12 that settles it.
    function test_r19_1_void_keepsTheReservation_onlySettlementReleases() public {
        IICS26RouterMsgs.Packet[] memory p = _hiddenRefunds(1, 100, 100);
        assertEq(ctl.reserved(clientId, address(usdc)), 100);
        vm.expectRevert(T.GnoBadProof.selector);
        ctl.voidOutcome(clientId, p[0].sequence); // still vouched for
        MockLightClient next = new MockLightClient();
        vm.prank(address(admin));
        router.migrateClient("gnoland-9", IICS02ClientMsgs.CounterpartyInfo("ethereum-9", _prefix()), address(next));
        ctl.voidOutcome(clientId, p[0].sequence);
        assertEq(uint8(ctl.sendRecord(clientId, p[0].sequence).proven), uint8(T.Proven.None));
        assertEq(ctl.reserved(clientId, address(usdc)), 100, "a void keeps the liability");
        _proveDelivered(p[0]); // a proof of delivery releases nothing by itself
        assertEq(ctl.reserved(clientId, address(usdc)), 100, "kept until settled");
        _settle(_item(p[0].sequence, 3, 0)); // settled as delivered
        assertEq(ctl.reserved(clientId, address(usdc)), 0, "released by the settlement");
    }

    /// @notice r19 #1, Codex's sequence: two hidden refunds of 100 proven (200 reserved) against 150; the verifier
    /// replaced (both proofs void); the second voided, only the first proven again and settled: it must not pay,
    /// the second's liability still holding its backing.
    function test_r19_1_voidThenSelectiveReproof_noPaymentTakesTheOthersBacking() public {
        IICS26RouterMsgs.Packet[] memory p = _hiddenRefunds(2, 100, 150);
        MockLightClient next = new MockLightClient();
        vm.prank(address(admin));
        router.migrateClient("gnoland-9", IICS02ClientMsgs.CounterpartyInfo("ethereum-9", _prefix()), address(next));
        ctl.voidOutcome(clientId, p[1].sequence);
        assertEq(ctl.reserved(clientId, address(usdc)), 200);
        _proveRefundable(p[0]);
        _settle(_item(p[0].sequence, 1, 100));
        assertEq(ctl.sendRecord(clientId, p[0].sequence).refunded, 0, "the first pays nothing");
        assertEq(usdc.balanceOf(ics20.getEscrow(clientId)), 150);
        _proveRefundable(p[1]);
        _settle(_item(p[1].sequence, 1, 100));
        assertEq(ctl.reserved(clientId, address(usdc)), 200);
    }

    /// @notice r19 #2: a route's receive limits wait for its quarantine to be armed.
    function test_r19_2_limitsWaitForTheQuarantine() public {
        vm.startPrank(address(admin));
        vm.expectRevert(T.GnoBadLimits.selector);
        ctl.setLimits("gnoland-77", address(usdc), T.Limits(1, 1, 1, 0, 0));
        ctl.setQuarantine("gnoland-77", 7 days);
        ctl.setLimits("gnoland-77", address(usdc), T.Limits(1, 1, 1, 0, 0));
        vm.stopPrank();
    }

    /// @notice r19 #3: a kind 10 whose migration is refused (its target already used: it has an escrow of its own)
    /// is spent and leaves no trace: the quarantine checkpoint and its verifier generation bump roll back with it, so
    /// outcomes proven before stay usable and cannot be voided.
    function test_r19_3_refusedKind10_keepsTheProofs() public {
        _setLimits(address(usdc), 1000, 1000, 1000);
        IICS26RouterMsgs.Packet memory a = _send(alice, address(usdc), 100, clientId);
        _retire();
        _proveRefundable(a);
        // the target enrolled by kind 6, then used: an escrow of its own
        MockLightClient c2 = new MockLightClient();
        uint64 seq = admin.lastSeq() + 1;
        _recvGov(
            _env(
                seq, S.KIND_CLIENT, P.client(1, "gnoland-2", "ethereum-2", _prefix(), address(c2), address(c2).codehash)
            )
        );
        _skip(7 days);
        admin.execute(seq);
        vm.startPrank(address(admin));
        ctl.setQuarantine("gnoland-2", 0);
        ctl.setLimits("gnoland-2", address(usdc), T.Limits(1000, 1000, 1000, 0, 0));
        vm.stopPrank();
        _send(alice, address(usdc), 1, "gnoland-2");
        assertTrue(ics20.getEscrow("gnoland-2") != address(0));
        uint64 route = admin.lastSeq() + 1;
        _recvGov(_env(route, S.KIND_ROUTE, P.route(clientId, "gnoland-2")));
        _skip(7 days);
        admin.execute(route);
        assertEq(_state(route), S.SPENT, "the migration refused");
        assertEq(admin.epoch(), 1);
        // the proof still stands: it cannot be voided, and it settles
        vm.expectRevert(T.GnoBadProof.selector);
        ctl.voidOutcome(clientId, a.sequence);
        _settle(_item(a.sequence, 1, 100));
        assertEq(ctl.sendRecord(clientId, a.sequence).refunded, 100);
    }

    // ============================================================================================= round 20 ==

    /// @notice r20 #1: two hidden refunds of 100 against 150, both acks inside the suspect interval of a kind 10
    /// replacement; proven and paid one at a time. Their reservations do not wait for the proofs: the incident's
    /// preparation holds every unsettled suspect success, and kind 12 pays nothing before it. Then neither payment
    /// can take the other's backing, whatever the proof order.
    function _staggered(uint256 n, uint256 each, uint256 left) internal returns (IICS26RouterMsgs.Packet[] memory p) {
        _setLimits(address(usdc), 1e9, 1e9, 1e9);
        p = new IICS26RouterMsgs.Packet[](n);
        uint64 from = uint64(block.number);
        for (uint256 i = 0; i < n; i++) {
            p[i] = _send(alice, address(usdc), each, clientId);
            _ack(p[i], bytes("{\"result\":\"AQ==\"}")); // forged success acks
        }
        _transferIn(
            clientId, string.concat("transfer/", CP, "/", Strings.toHexString(address(usdc))), n * each - left, bob
        );
        MockLightClient lc2 = new MockLightClient();
        uint64 add = _decide(
            S.KIND_CLIENT, P.client(1, "gnoland-2", "ethereum-2", _prefix(), address(lc2), address(lc2).codehash)
        );
        uint64 replace = _decide(S.KIND_ROUTE, P.route(clientId, "gnoland-2", from));
        _skip(7 days);
        admin.execute(add);
        admin.execute(replace);
        assertEq(admin.decision(1, replace).state, S.EXECUTED);
    }

    function test_r20_1_staggeredProofs_noPaymentBeforePreparation_noneTakesTheOthersBacking() public {
        IICS26RouterMsgs.Packet[] memory p = _staggered(2, 100, 150);
        address escrow = ics20.getEscrow(clientId);
        // proven and settled before the preparation: parked, nothing leaves the escrow
        _proveRefundable(p[0]);
        vm.prank(address(admin));
        ctl.settleRecords(clientId, _item(p[0].sequence, 1, 100));
        assertEq(usdc.balanceOf(escrow), 150, "no refund before the preparation");
        // prepared (anyone, in batches): both suspect successes reserved
        assertEq(ctl.prepareIncident(clientId, 1), 1);
        assertEq(ctl.prepareIncident(clientId, 1), 0);
        assertEq(ctl.reserved(clientId, address(usdc)), 200);
        // B proven later: still no payment can take A's or B's backing
        _proveRefundable(p[1]);
        vm.prank(address(admin));
        ctl.settleRecords(clientId, _item(p[1].sequence, 1, 100));
        assertEq(usdc.balanceOf(escrow), 150);
        assertEq(ctl.reserved(clientId, address(usdc)), 200);
    }

    /// @notice r20 #1, nine staggered hidden refunds of 10 against 80, crossing the eight-item batch: prepared, then
    /// proven and settled one at a time, none pays.
    function test_r20_1_staggeredProofs_nineAcrossTheBatchBoundary() public {
        IICS26RouterMsgs.Packet[] memory p = _staggered(9, 10, 80);
        while (ctl.prepareIncident(clientId, 4) != 0) { }
        assertEq(ctl.reserved(clientId, address(usdc)), 90);
        T.SettleItem[] memory items = new T.SettleItem[](8);
        for (uint256 i = 0; i < 8; i++) {
            _proveRefundable(p[i]);
            items[i] = T.SettleItem(p[i].sequence, 1, 10);
        }
        vm.prank(address(admin));
        ctl.settleRecords(clientId, items);
        _proveRefundable(p[8]);
        vm.prank(address(admin));
        ctl.settleRecords(clientId, _item(p[8].sequence, 1, 10));
        for (uint256 i = 0; i < 9; i++) {
            assertEq(ctl.sendRecord(clientId, p[i].sequence).refunded, 0);
        }
        assertEq(usdc.balanceOf(ics20.getEscrow(clientId)), 80);
    }

    /// @notice r20: a prepared suspect success proven delivered stays held; the kind 12 that settles it releases it.
    function test_r20_1_deliveredProof_releasesOnlyAtSettlement() public {
        IICS26RouterMsgs.Packet[] memory p = _staggered(1, 100, 50);
        ctl.prepareIncident(clientId, 8);
        assertEq(ctl.reserved(clientId, address(usdc)), 100);
        _proveDelivered(p[0]);
        assertEq(ctl.reserved(clientId, address(usdc)), 100, "a proof releases nothing");
        vm.prank(address(admin));
        ctl.settleRecords(clientId, _item(p[0].sequence, 3, 0));
        assertEq(ctl.reserved(clientId, address(usdc)), 0, "released by the settlement");
    }

    /// @notice r20 (the gno side's round 39 class): A's success proven delivered, B's hidden refund proven owed, both
    /// held (200) against 150; the verifier then replaced (A's proof void). B settled before A is proven again must
    /// not take A's backing: A stays held, B parks. In both proof orders.
    function _deliveredVoidThenSibling(bool bFirst) internal {
        IICS26RouterMsgs.Packet[] memory p = _staggered(2, 100, 150);
        ctl.prepareIncident(clientId, 8);
        assertEq(ctl.reserved(clientId, address(usdc)), 200);
        if (bFirst) _proveRefundable(p[1]);
        _proveDelivered(p[0]);
        if (!bFirst) _proveRefundable(p[1]);
        // the verifier replaced: A's proof (and B's) void
        MockLightClient next = new MockLightClient();
        vm.prank(address(admin));
        router.migrateClient("gnoland-2", IICS02ClientMsgs.CounterpartyInfo("ethereum-2", _prefix()), address(next));
        ctl.voidOutcome(clientId, p[0].sequence);
        assertEq(ctl.reserved(clientId, address(usdc)), 200, "A held through the void");
        _proveRefundable(p[1]);
        vm.prank(address(admin));
        ctl.settleRecords(clientId, _item(p[1].sequence, 1, 100));
        assertEq(ctl.sendRecord(clientId, p[1].sequence).refunded, 0, "B never takes A's backing");
        assertEq(usdc.balanceOf(ics20.getEscrow(clientId)), 150);
    }

    function test_r20_1_deliveredThenVoid_siblingCannotDrain() public {
        _deliveredVoidThenSibling(false);
    }

    function test_r20_1_deliveredThenVoid_siblingCannotDrain_reversed() public {
        _deliveredVoidThenSibling(true);
    }

    /// @notice r20: the honest batch: A proven delivered, B proven owed, 100 left for B. One kind 12 settles A as
    /// delivered (releasing it in the first pass) and pays B in the second.
    function test_r20_1_batchReleasesADeliveredRecord_andPaysTheSibling() public {
        IICS26RouterMsgs.Packet[] memory p = _staggered(2, 100, 100);
        ctl.prepareIncident(clientId, 8);
        _proveDelivered(p[0]);
        _proveRefundable(p[1]);
        T.SettleItem[] memory items = new T.SettleItem[](2);
        items[0] = T.SettleItem(p[1].sequence, 1, 100); // the payment first in the list: the passes order it
        items[1] = T.SettleItem(p[0].sequence, 3, 0);
        vm.prank(address(admin));
        ctl.settleRecords(clientId, items);
        assertEq(ctl.sendRecord(clientId, p[1].sequence).refunded, 100, "B paid");
        assertEq(ctl.reserved(clientId, address(usdc)), 0);
    }
}
