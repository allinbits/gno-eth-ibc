// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Vm } from "forge-std/Vm.sol";
import { IERC20 } from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import { IAccessManager } from "@openzeppelin-contracts/access/manager/IAccessManager.sol";
import { ISignatureTransfer } from "@uniswap/permit2/src/interfaces/ISignatureTransfer.sol";

import { IICS20Transfer } from "@eureka/interfaces/IICS20Transfer.sol";
import { IICS26Router } from "@eureka/interfaces/IICS26Router.sol";
import { IICS26RouterMsgs } from "@eureka/msgs/IICS26RouterMsgs.sol";
import { IICS02ClientMsgs } from "@eureka/msgs/IICS02ClientMsgs.sol";
import { IICS20TransferMsgs } from "@eureka/msgs/IICS20TransferMsgs.sol";
import { IBCRolesLib } from "@eureka/utils/IBCRolesLib.sol";
import { ICS20Lib } from "@eureka/utils/ICS20Lib.sol";

import { GnoICS20Transfer } from "../../src/GnoICS20Transfer.sol";
import { GnoICS20Controls } from "../../src/transfer/GnoICS20Controls.sol";
import { GnoICS20Reconcile } from "../../src/transfer/GnoICS20Reconcile.sol";
import { IGnoICS20ControlsTypes as T } from "../../src/interfaces/IGnoICS20Controls.sol";
import { IGuardians } from "../../src/interfaces/IGuardians.sol";
import { IIBCAdmin } from "../../src/interfaces/IIBCAdmin.sol";
import { IBCAdmin } from "../../src/admin/IBCAdmin.sol";
import { IBCAdminStorage as S } from "../../src/admin/IBCAdminStorage.sol";
import { GovParams as P } from "../utils/GovParams.sol";
import { MockLightClient } from "../utils/MockLightClient.sol";
import { RefusingToken } from "../utils/RefusingToken.sol";
import { MockPermit2, SenderAdapter, ReentrantToken } from "../utils/ControlsMocks.sol";
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
        ctl.migrateRoute(clientId, "gnoland-9");
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
        vm.prank(address(admin));
        vm.expectRevert(abi.encodeWithSelector(T.GnoBadSettlement.selector, 0));
        ctl.settleRecords(clientId, _item(pkt.sequence, 1, 200)); // a haircut is refused
        r.setBlocked(alice, true);
        _settle(_item(pkt.sequence, 1, 500));
        assertEq(uint8(ctl.sendRecord(clientId, pkt.sequence).payment), uint8(T.Payment.Parked));
        r.setBlocked(alice, false);
        vm.prank(address(admin));
        ctl.reopenRoute(clientId);
        assertEq(ctl.claimParked(clientId, pkt.sequence), 500);
        assertEq(r.balanceOf(alice), 1000);
    }

    function test_r1_settleAndReopen_byDecision() public {
        IICS26RouterMsgs.Packet memory pkt;
        _setLimits(address(usdc), 1000, 1000, 1000);
        pkt = _send(alice, address(usdc), 100, clientId);
        _retire();
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
        address impl = address(new GnoICS20Transfer(address(new GnoICS20Controls(address(new GnoICS20Reconcile())))));
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
                recovery: IIBCAdmin.RecoveryConfig(30 days, threshold, cancelThreshold, 30 days, 14 days)
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
        _adminWith(3, 2);
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
        ctl.migrateRoute(clientId, "gnoland-9");
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
        ctl.retryNotification(clientId, pkt.sequence); // nothing kept yet
        _timeout(pkt); // refund paid, notification refused
        assertEq(usdc.balanceOf(address(adapter)), 500);
        assertFalse(ctl.retryNotification(clientId, pkt.sequence)); // still refusing: kept
        adapter.setRefuse(false);
        vm.prank(alice); // anyone
        assertTrue(ctl.retryNotification(clientId, pkt.sequence));
        assertEq(adapter.notices(), 1);
        assertEq(usdc.balanceOf(bob), 500, "forwarded the refund it was paid once");
        vm.expectRevert(abi.encodeWithSelector(T.GnoNoNotification.selector, clientId, pkt.sequence));
        ctl.retryNotification(clientId, pkt.sequence);
        assertEq(ctl.sendRecord(clientId, pkt.sequence).refunded, 500);
    }

    // ================================================================ #16, #18 port and envelope boundary ==

    function test_r18_envelope1024Recorded_1025Spent() public {
        bytes memory params = P.settings(clientId, 1 days);
        bytes memory at = _env(1, S.KIND_SETTINGS, bytes.concat(params, new bytes(1024 - 14 - params.length)));
        assertEq(at.length, 1024);
        assertEq(_status(_recvGov(at)), S.STATUS_RECORDED);
        assertEq(_state(1), S.PENDING);
        bytes memory over = _env(2, S.KIND_SETTINGS, bytes.concat(params, new bytes(1025 - 14 - params.length)));
        assertEq(over.length, 1025);
        assertEq(_status(_recvGov(over)), S.STATUS_SPENT);
        assertEq(admin.PORT(), "ibcgov");
        assertEq(admin.COUNTERPARTY_PORT(), "gov");
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
}
