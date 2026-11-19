// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Vm } from "forge-std/Vm.sol";
import { IICS26Router } from "@eureka/interfaces/IICS26Router.sol";
import { IICS26RouterMsgs } from "@eureka/msgs/IICS26RouterMsgs.sol";
import { IICS02ClientMsgs } from "@eureka/msgs/IICS02ClientMsgs.sol";
import { ICS24Host } from "@eureka/utils/ICS24Host.sol";

import { IIBCAdmin } from "../../src/interfaces/IIBCAdmin.sol";
import { IBCAdmin } from "../../src/admin/IBCAdmin.sol";
import { IBCAdminExec } from "../../src/admin/IBCAdminExec.sol";
import { IIBCAppCallbacks } from "@eureka/msgs/IIBCAppCallbacks.sol";
import { IBCAdminStorage as S } from "../../src/admin/IBCAdminStorage.sol";
import { GovParams as P } from "../utils/GovParams.sol";
import { MockLightClient } from "../utils/MockLightClient.sol";
import { ControlsFixture } from "./ControlsFixture.sol";

/// @notice Another IBC app, whose receive callback calls IBCAdmin's permissionless `execute` (the router locked).
contract ExecutingApp {
    IBCAdmin internal immutable admin;
    uint64 public seq;

    constructor(IBCAdmin a) {
        admin = a;
    }

    function arm(uint64 s) external {
        seq = s;
    }

    function onRecvPacket(IIBCAppCallbacks.OnRecvPacketCallback calldata) external returns (bytes memory) {
        admin.execute(seq);
        return bytes("ok");
    }

    function onAcknowledgementPacket(IIBCAppCallbacks.OnAcknowledgementPacketCallback calldata) external { }

    function onTimeoutPacket(IIBCAppCallbacks.OnTimeoutPacketCallback calldata) external { }
}

/// @notice ADR §7.12, the two-phase epoch switch: each executed kind 10 (or emergency recovery) raises the epoch by
/// one and sends that epoch's notice from `ibcgov` over its new client to gno.land's `gov` port. gno.land answers in
/// IBCAdmin's ack layout (status 1 switched, 3 already switched); an error ack or a timeout acknowledges nothing.
/// Anyone re-sends any recorded notice, with the same bytes, by epoch, at any time (even after an ack).
contract EpochNoticeTest is ControlsFixture {
    function _prefix() internal pure returns (bytes[] memory p) {
        p = new bytes[](2);
        p[0] = "main";
        p[1] = "/pv/vm:gno.land/r/aib/ibc/core:";
    }

    /// @notice Kind 6 enrolls `next`, kind 10 moves the route to it; returns the notice packet the router committed.
    function _replace(string memory next, string memory cp) internal returns (IICS26RouterMsgs.Packet memory pkt) {
        MockLightClient c = new MockLightClient();
        uint64 seq = admin.lastSeq() + 1;
        _recvGov(_env(seq, S.KIND_CLIENT, P.client(1, next, cp, _prefix(), address(c), address(c).codehash)));
        _recvGov(_env(seq + 1, S.KIND_ROUTE, P.route(admin.govClient(), next)));
        _skip(7 days);
        admin.execute(seq);
        vm.recordLogs();
        admin.execute(seq + 1);
        pkt = _sentNotice();
    }

    function _sentNotice() internal returns (IICS26RouterMsgs.Packet memory pkt) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(router) && logs[i].topics[0] == IICS26Router.SendPacket.selector) {
                return abi.decode(logs[i].data, (IICS26RouterMsgs.Packet));
            }
        }
        revert("no notice sent");
    }

    function _gnoAck(uint32 epoch, uint8 status) internal pure returns (bytes memory) {
        return abi.encodePacked(epoch, uint64(0), status, uint8(0));
    }

    function _ackNotice(IICS26RouterMsgs.Packet memory pkt, bytes memory ack) internal {
        router.ackPacket(IICS26RouterMsgs.MsgAckPacket(pkt, ack, "", IICS02ClientMsgs.Height(0, 1)));
    }

    function test_epochNotice_sentOverTheNewClient_ackedOnce() public {
        IICS26RouterMsgs.Packet memory pkt = _replace("gnoland-2", "ethereum-2");
        assertEq(admin.epoch(), 2);
        bytes memory notice = abi.encodePacked(uint8(1), uint32(2), "gnoland-2");
        assertEq(admin.epochNotice(2), notice);
        assertEq(pkt.sourceClient, "gnoland-2", "over the new client");
        assertEq(pkt.destClient, "ethereum-2");
        assertEq(pkt.payloads[0].sourcePort, "ibcgov");
        assertEq(pkt.payloads[0].destPort, "gov");
        assertEq(pkt.payloads[0].version, "ibcgov-1");
        assertEq(pkt.payloads[0].encoding, "application/x-ibcgov");
        assertEq(pkt.payloads[0].value, notice);
        assertEq(pkt.timeoutTimestamp, _now() + 23 hours);
        // an error ack leaves it owed: re-sent with the same bytes
        _ackNotice(pkt, ICS24Host.UNIVERSAL_ERROR_ACK);
        assertFalse(admin.epochNoticeAcked(2));
        vm.recordLogs();
        admin.resendEpochNotice(2);
        IICS26RouterMsgs.Packet memory again = _sentNotice();
        assertEq(again.payloads[0].value, notice);
        assertEq(again.sequence, pkt.sequence + 1);
        // an ack of another epoch, or another status, ends nothing
        _ackNotice(again, _gnoAck(3, 1));
        vm.recordLogs();
        admin.resendEpochNotice(2);
        IICS26RouterMsgs.Packet memory third = _sentNotice();
        _ackNotice(third, _gnoAck(2, 2));
        assertFalse(admin.epochNoticeAcked(2));
        // a timeout: not acknowledged
        vm.recordLogs();
        admin.resendEpochNotice(2);
        IICS26RouterMsgs.Packet memory fourth = _sentNotice();
        MockLightClient c2 = MockLightClient(address(router.getClient("gnoland-2")));
        c2.setTimestamp(fourth.timeoutTimestamp);
        router.timeoutPacket(IICS26RouterMsgs.MsgTimeoutPacket(fourth, "", IICS02ClientMsgs.Height(0, 1)));
        c2.setTimestamp(0);
        assertFalse(admin.epochNoticeAcked(2));
        vm.recordLogs();
        admin.resendEpochNotice(2);
        IICS26RouterMsgs.Packet memory fifth = _sentNotice();
        // gno.land switched (status 1): done; or already switched (3) for a duplicate
        _ackNotice(fifth, _gnoAck(2, 1));
        assertTrue(admin.epochNoticeAcked(2), "acknowledged");
        admin.resendEpochNotice(2); // still re-sendable
    }

    function test_epochNotice_duplicateAck_status3_acknowledges() public {
        IICS26RouterMsgs.Packet memory pkt = _replace("gnoland-2", "ethereum-2");
        _ackNotice(pkt, _gnoAck(2, 3));
        assertTrue(admin.epochNoticeAcked(2), "acknowledged");
        admin.resendEpochNotice(2); // still re-sendable
    }

    /// @notice A→B→C: epoch 2's notice over B, epoch 3's over C, each re-sendable on its own (gno.land may skip
    /// ahead to C's), each with its own bytes over its own client.
    function test_epochNotice_consecutiveReplacements_eachResendable() public {
        IICS26RouterMsgs.Packet memory b = _replace("gnoland-2", "ethereum-2");
        IICS26RouterMsgs.Packet memory c = _replace("gnoland-3", "ethereum-3");
        assertEq(admin.epoch(), 3);
        assertEq(b.payloads[0].value, abi.encodePacked(uint8(1), uint32(2), "gnoland-2"));
        assertEq(c.payloads[0].value, abi.encodePacked(uint8(1), uint32(3), "gnoland-3"));
        assertEq(c.sourceClient, "gnoland-3");
        vm.recordLogs();
        admin.resendEpochNotice(2);
        IICS26RouterMsgs.Packet memory b2 = _sentNotice();
        assertEq(b2.sourceClient, "gnoland-2");
        assertEq(b2.payloads[0].value, b.payloads[0].value);
        vm.recordLogs();
        admin.resendEpochNotice(3);
        IICS26RouterMsgs.Packet memory c2 = _sentNotice();
        assertEq(c2.sourceClient, "gnoland-3");
        assertEq(c2.payloads[0].value, c.payloads[0].value);
        // C's acknowledged: epoch 2's stays unacknowledged on its own
        _ackNotice(c2, _gnoAck(3, 1));
        assertTrue(admin.epochNoticeAcked(3), "acknowledged");
        admin.resendEpochNotice(3); // still re-sendable
        assertFalse(admin.epochNoticeAcked(2));
        admin.resendEpochNotice(2);
        // no notice for the launch epoch
        vm.expectRevert(IIBCAdmin.NoNotice.selector);
        admin.resendEpochNotice(1);
    }

    /// @notice A kind 10 executed inside another app's receive callback (the router locked): the epoch switch stands,
    /// the initial notice send is refused and the notice stays owed; a later resend goes out, and its ack ends it.
    function test_epochNotice_refusedInitialSend_resendCompletes() public {
        ExecutingApp app = new ExecutingApp(admin);
        vm.prank(address(admin));
        router.addIBCApp("probe", address(app));
        MockLightClient c = new MockLightClient();
        uint64 seq = admin.lastSeq() + 1;
        _recvGov(
            _env(seq, S.KIND_CLIENT, P.client(1, "gnoland-2", "ethereum-2", _prefix(), address(c), address(c).codehash))
        );
        _recvGov(_env(seq + 1, S.KIND_ROUTE, P.route(clientId, "gnoland-2")));
        _skip(7 days);
        admin.execute(seq);
        app.arm(seq + 1);
        IICS26RouterMsgs.Packet memory pkt = _packetFromGno(clientId, "probe", "v", "e", "x");
        vm.recordLogs();
        router.recvPacket(IICS26RouterMsgs.MsgRecvPacket(pkt, "", IICS02ClientMsgs.Height(0, 1)));
        assertEq(admin.epoch(), 2, "the epoch switch stands");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(
                !(logs[i].emitter == address(router) && logs[i].topics[0] == IICS26Router.SendPacket.selector),
                "no notice sent from inside the lock"
            );
        }
        bytes memory notice = abi.encodePacked(uint8(1), uint32(2), "gnoland-2");
        assertEq(admin.epochNotice(2), notice, "owed");
        vm.recordLogs();
        admin.resendEpochNotice(2);
        IICS26RouterMsgs.Packet memory sent = _sentNotice();
        assertEq(sent.sourceClient, "gnoland-2");
        assertEq(sent.payloads[0].value, notice);
        _ackNotice(sent, _gnoAck(2, 1));
        assertTrue(admin.epochNoticeAcked(2), "acknowledged");
        admin.resendEpochNotice(2); // still re-sendable
    }

    /// @notice An ack in the right epoch and status but a non-zero sequence or redispatch field acknowledges
    /// nothing.
    function test_epochNotice_malformedAckFields_acknowledgeNothing() public {
        IICS26RouterMsgs.Packet memory pkt = _replace("gnoland-2", "ethereum-2");
        _ackNotice(pkt, abi.encodePacked(uint32(2), uint64(1), uint8(1), uint8(0))); // seq 1
        assertFalse(admin.epochNoticeAcked(2));
        vm.recordLogs();
        admin.resendEpochNotice(2);
        IICS26RouterMsgs.Packet memory again = _sentNotice();
        _ackNotice(again, abi.encodePacked(uint32(2), uint64(0), uint8(1), uint8(1))); // redispatch 1
        assertFalse(admin.epochNoticeAcked(2));
        vm.recordLogs();
        admin.resendEpochNotice(2);
        IICS26RouterMsgs.Packet memory third = _sentNotice();
        _ackNotice(third, abi.encodePacked(uint32(2), uint64(0), uint8(3), uint8(0)));
        assertTrue(admin.epochNoticeAcked(2), "acknowledged");
        admin.resendEpochNotice(2); // still re-sendable
    }

    // ============================================== round 22: catch-up resends (gno design review round 4, P1) ==

    function _noAdminAckEvent() internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(
                !(logs[i].emitter == address(admin) && logs[i].topics[0] == IIBCAdmin.EpochNoticeAcknowledged.selector),
                "a repeat ack is ignored"
            );
        }
    }

    /// @notice An acknowledgement (which a compromised verifier could forge) never ends resends: the notice goes out
    /// again in a fresh packet with the same bytes, and an ack of an epoch already acknowledged is ignored.
    function test_r22_resendAfterAck_freshPacket_repeatAckIgnored() public {
        IICS26RouterMsgs.Packet memory pkt = _replace("gnoland-2", "ethereum-2");
        _ackNotice(pkt, _gnoAck(2, 1));
        assertTrue(admin.epochNoticeAcked(2));
        vm.recordLogs();
        admin.resendEpochNotice(2);
        IICS26RouterMsgs.Packet memory again = _sentNotice();
        assertEq(again.sourceClient, "gnoland-2");
        assertEq(again.sequence, pkt.sequence + 1, "a fresh packet");
        assertEq(again.payloads[0].value, pkt.payloads[0].value, "the same bytes");
        assertEq(again.payloads[0].destPort, "gov");
        vm.recordLogs();
        _ackNotice(again, _gnoAck(2, 3));
        _noAdminAckEvent();
        assertTrue(admin.epochNoticeAcked(2));
        // and once more, still
        vm.recordLogs();
        admin.resendEpochNotice(2);
        assertEq(_sentNotice().sequence, pkt.sequence + 2);
    }

    /// @notice A→B→C retires B (its id migrated to the frozen light client): epoch 2's notice still goes out over
    /// B,
    /// even after it was acknowledged. eureka's `sendPacket` reads only B's counterparty, never its light client,
    /// so neither the retirement nor a frozen verifier blocks it. Such a packet can never be acknowledged or timed
    /// out on Ethereum (the frozen client verifies nothing); it needs neither.
    function test_r22_resendOverARetiredClient() public {
        IICS26RouterMsgs.Packet memory b = _replace("gnoland-2", "ethereum-2");
        _ackNotice(b, _gnoAck(2, 1));
        _replace("gnoland-3", "ethereum-3");
        assertEq(admin.govClient(), "gnoland-3");
        (address x,) = admin.exec();
        assertEq(address(router.getClient("gnoland-2")), IBCAdminExec(x).frozenClient(), "retired");
        vm.recordLogs();
        admin.resendEpochNotice(2);
        IICS26RouterMsgs.Packet memory again = _sentNotice();
        assertEq(again.sourceClient, "gnoland-2", "over epoch 2's own client");
        assertEq(again.destClient, "ethereum-2");
        assertEq(again.payloads[0].value, abi.encodePacked(uint8(1), uint32(2), "gnoland-2"));
        assertEq(again.sequence, b.sequence + 1);
        vm.expectRevert(); // the frozen client verifies nothing: no ack lands on Ethereum
        router.ackPacket(IICS26RouterMsgs.MsgAckPacket(again, _gnoAck(2, 1), "", IICS02ClientMsgs.Height(0, 1)));
        // a frozen verifier on the live client does not block sending either
        MockLightClient(address(router.getClient("gnoland-3"))).setStatus(true, false);
        vm.recordLogs();
        admin.resendEpochNotice(3);
        assertEq(_sentNotice().sourceClient, "gnoland-3");
    }

    /// @notice Resending an old epoch's notice while a newer epoch is current changes nothing of IBCAdmin's
    /// governance state (epoch, client, sequence window, silence, flags, decisions, other notices).
    function test_r22_resendOldEpoch_changesNothing() public {
        _replace("gnoland-2", "ethereum-2");
        IICS26RouterMsgs.Packet memory c = _replace("gnoland-3", "ethereum-3");
        _ackNotice(c, _gnoAck(3, 1));
        _skip(1 days);
        uint32 ep = admin.epoch();
        string memory gc = admin.govClient();
        uint64 last = admin.lastSeq();
        uint64 rec = admin.lastRecordTime();
        uint64 conflict = admin.conflictBlock();
        bytes memory n2 = admin.epochNotice(2);
        bytes memory n3 = admin.epochNotice(3);
        bytes32 slot0 = vm.load(address(admin), S.SLOT);
        admin.resendEpochNotice(2);
        admin.resendEpochNotice(2);
        assertEq(admin.epoch(), ep);
        assertEq(admin.govClient(), gc);
        assertEq(admin.lastSeq(), last);
        assertEq(admin.lastRecordTime(), rec);
        assertEq(admin.conflictBlock(), conflict);
        assertEq(admin.epochNotice(2), n2);
        assertEq(admin.epochNotice(3), n3);
        assertFalse(admin.epochNoticeAcked(2));
        assertTrue(admin.epochNoticeAcked(3));
        assertEq(vm.load(address(admin), S.SLOT), slot0);
        // governance still records in the current epoch
        assertEq(_status(_recvGov(_env(last + 1, S.KIND_UNPAUSE, P.unpause(2, "")))), S.STATUS_RECORDED);
    }

    /// @notice A resend of an acknowledged epoch's notice that gno.land refuses (a passed epoch) times out: the
    /// timeout changes nothing on Ethereum, the notice stays acknowledged and re-sendable.
    function test_r22_timeoutOfAnAckedResend_changesNothing() public {
        IICS26RouterMsgs.Packet memory pkt = _replace("gnoland-2", "ethereum-2");
        _ackNotice(pkt, _gnoAck(2, 1));
        vm.recordLogs();
        admin.resendEpochNotice(2);
        IICS26RouterMsgs.Packet memory again = _sentNotice();
        uint64 last = admin.lastSeq();
        bytes32 slot0 = vm.load(address(admin), S.SLOT);
        MockLightClient c2 = MockLightClient(address(router.getClient("gnoland-2")));
        c2.setTimestamp(again.timeoutTimestamp);
        router.timeoutPacket(IICS26RouterMsgs.MsgTimeoutPacket(again, "", IICS02ClientMsgs.Height(0, 1)));
        c2.setTimestamp(0);
        assertTrue(admin.epochNoticeAcked(2), "still acknowledged");
        assertEq(admin.epoch(), 2);
        assertEq(admin.lastSeq(), last);
        assertEq(vm.load(address(admin), S.SLOT), slot0);
        admin.resendEpochNotice(2);
    }
}
