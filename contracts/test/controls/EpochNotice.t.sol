// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Vm } from "forge-std/Vm.sol";
import { IICS26Router } from "@eureka/interfaces/IICS26Router.sol";
import { IICS26RouterMsgs } from "@eureka/msgs/IICS26RouterMsgs.sol";
import { IICS02ClientMsgs } from "@eureka/msgs/IICS02ClientMsgs.sol";
import { ICS24Host } from "@eureka/utils/ICS24Host.sol";

import { IIBCAdmin } from "../../src/interfaces/IIBCAdmin.sol";
import { IBCAdminStorage as S } from "../../src/admin/IBCAdminStorage.sol";
import { GovParams as P } from "../utils/GovParams.sol";
import { MockLightClient } from "../utils/MockLightClient.sol";
import { ControlsFixture } from "./ControlsFixture.sol";

/// @notice ADR §7.12, the two-phase epoch switch: each executed kind 10 (or emergency recovery) raises the epoch by
/// one and sends that epoch's notice from `ibcgov` over its new client to gno.land's `gov` port. gno.land answers in
/// IBCAdmin's ack layout (status 1 switched, 3 already switched); an error ack or a timeout leaves the notice owed,
/// and anyone re-sends it, with the same bytes, by epoch.
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
        // a timeout: still owed
        vm.recordLogs();
        admin.resendEpochNotice(2);
        IICS26RouterMsgs.Packet memory fourth = _sentNotice();
        MockLightClient c2 = MockLightClient(address(router.getClient("gnoland-2")));
        c2.setTimestamp(fourth.timeoutTimestamp);
        router.timeoutPacket(IICS26RouterMsgs.MsgTimeoutPacket(fourth, "", IICS02ClientMsgs.Height(0, 1)));
        c2.setTimestamp(0);
        vm.recordLogs();
        admin.resendEpochNotice(2);
        IICS26RouterMsgs.Packet memory fifth = _sentNotice();
        // gno.land switched (status 1): done; or already switched (3) for a duplicate
        _ackNotice(fifth, _gnoAck(2, 1));
        vm.expectRevert(IIBCAdmin.NoNoticeOwed.selector);
        admin.resendEpochNotice(2);
    }

    function test_epochNotice_duplicateAck_status3_endsIt() public {
        IICS26RouterMsgs.Packet memory pkt = _replace("gnoland-2", "ethereum-2");
        _ackNotice(pkt, _gnoAck(2, 3));
        vm.expectRevert(IIBCAdmin.NoNoticeOwed.selector);
        admin.resendEpochNotice(2);
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
        // C's acknowledged: epoch 2's stays owed on its own
        _ackNotice(c2, _gnoAck(3, 1));
        vm.expectRevert(IIBCAdmin.NoNoticeOwed.selector);
        admin.resendEpochNotice(3);
        admin.resendEpochNotice(2);
        // no notice for the launch epoch
        vm.expectRevert(IIBCAdmin.NoNoticeOwed.selector);
        admin.resendEpochNotice(1);
    }
}
