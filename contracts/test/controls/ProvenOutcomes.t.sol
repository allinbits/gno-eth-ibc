// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IICS26RouterMsgs } from "@eureka/msgs/IICS26RouterMsgs.sol";
import { IICS02ClientMsgs } from "@eureka/msgs/IICS02ClientMsgs.sol";
import { ICS24Host } from "@eureka/utils/ICS24Host.sol";

import { IGnoICS20ControlsTypes as T } from "../../src/interfaces/IGnoICS20Controls.sol";
import { IBCAdminStorage as S } from "../../src/admin/IBCAdminStorage.sol";
import { GovParams as P } from "../utils/GovParams.sol";
import { MockLightClient } from "../utils/MockLightClient.sol";
import { ControlsFixture } from "./ControlsFixture.sol";

/// @notice Round 4 #4: kind 12 settles a send record only against its destination outcome, proven through the
/// route's replacement client (`proveOutcome`, ADR §5.4 "Proven outcomes", §7.12). The replacement here is a mock
/// light client in strict mode: it proves only the (path, value) pairs the test sets, so every path, receipt and ack
/// commitment `proveOutcome` computes is checked.
contract ProvenOutcomesTest is ControlsFixture {
    MockLightClient internal lc9;
    bytes internal constant OK = bytes("{\"result\":\"AQ==\"}");

    function _prefix() internal pure returns (bytes[] memory p) {
        p = new bytes[](2);
        p[0] = "main";
        p[1] = "/pv/vm:gno.land/r/aib/ibc/core:";
    }

    /// @notice Replaces the route by `gnoland-9`, whose client is strict.
    function _replace() internal {
        lc9 = new MockLightClient();
        lc9.setStrict(true);
        vm.startPrank(address(admin));
        router.addClient("gnoland-9", IICS02ClientMsgs.CounterpartyInfo("ethereum-9", _prefix()), address(lc9));
        ctl.migrateRoute(clientId, "gnoland-9", type(uint64).max);
        vm.stopPrank();
    }

    function _receiptPath(IICS26RouterMsgs.Packet memory pkt) internal pure returns (bytes[] memory) {
        return ICS24Host.prefixedPath(
            _prefix(), ICS24Host.packetReceiptCommitmentPathCalldata(pkt.destClient, pkt.sequence)
        );
    }

    /// @notice The destination's state: `receipt` at the packet's receipt path and, if `ack` is not empty, its ack
    /// commitment at the ack path.
    function _destination(IICS26RouterMsgs.Packet memory pkt, bytes32 receipt, bytes memory ack) internal {
        lc9.setMember(_receiptPath(pkt), abi.encodePacked(receipt));
        if (ack.length != 0) {
            bytes[] memory acks = new bytes[](1);
            acks[0] = ack;
            lc9.setMember(
                ICS24Host.prefixedPath(
                    _prefix(), ICS24Host.packetAcknowledgementCommitmentPathCalldata(pkt.destClient, pkt.sequence)
                ),
                abi.encodePacked(ICS24Host.packetAcknowledgementCommitmentBytes32(acks))
            );
        }
    }

    function _proof(bytes32 receipt, bytes memory ack) internal pure returns (T.OutcomeProof memory) {
        return T.OutcomeProof(IICS02ClientMsgs.Height(0, 9), receipt, "rp", ack, "ap");
    }

    function _item(uint64 seq, uint8 action, uint256 amount) internal pure returns (T.SettleItem[] memory items) {
        items = new T.SettleItem[](1);
        items[0] = T.SettleItem(seq, action, amount);
    }

    function _settleReverts(uint64 seq, uint8 action, uint256 amount) internal {
        vm.prank(address(admin));
        vm.expectRevert(abi.encodeWithSelector(T.GnoBadSettlement.selector, 0));
        ctl.settleRecords(clientId, _item(seq, action, amount));
    }

    function _settle(uint64 seq, uint8 action, uint256 amount) internal {
        vm.prank(address(admin));
        ctl.settleRecords(clientId, _item(seq, action, amount));
    }

    // ------------------------------------------------------------------------------------------ R19 vector --

    /// @notice gno.land's receipt (R19), byte for byte the vectors of gno-realms
    /// `gno.land/p/aib/ibc/types/v0/commitment_test.gno` (TestCommitPacketReceipt, branch feat/ibc-controls).
    function test_r4_4_gnoReceipt_matchesTheGnoRealmsVector() public view {
        IICS26RouterMsgs.Payload[] memory pl = new IICS26RouterMsgs.Payload[](1);
        pl[0] = IICS26RouterMsgs.Payload(
            "transfer",
            "transfer",
            "ics20-1",
            "application/json",
            bytes(
                "{\"denom\":\"uatom\",\"amount\":\"1000000\",\"sender\":\"sender\",\"receiver\":\"receiver\",\"memo\":\"memo\"}"
            )
        );
        IICS26RouterMsgs.Packet memory p = IICS26RouterMsgs.Packet(1, "07-tendermint-0", "07-tendermint-1", 100, pl);
        assertEq(ctl.gnoReceipt(p), 0x149d890018aa558d56444db8254db1b5cdd008e80803ce359273f1e3b2d24727);
        p.sequence = 2;
        assertEq(ctl.gnoReceipt(p), 0xe39e640ffa0230188b3f2e1e44bbc9d8723844e682e54cd2153e713d1bb2ad16);
        p.sequence = 1;
        p.sourceClient = "07-tendermint-9";
        assertEq(ctl.gnoReceipt(p), 0xf8beb43efb246824a51db7040d17a1cba2f090710db4b3f9697701be2c86aac6);
    }

    // ------------------------------------------------------------------------------------------- outcomes --

    /// @notice Delivered: the packet's own receipt and a success ack. A refund is refused, "delivered" settles it;
    /// a forged success ack (here: processed) or an outstanding packet alike.
    function test_r4_4_delivered_onlySettledAsDelivered() public {
        _setLimits(address(usdc), 1000, 1000, 1000);
        IICS26RouterMsgs.Packet memory pkt = _send(alice, address(usdc), 100, clientId);
        _replace();
        bytes32 receipt = ctl.gnoReceipt(pkt);
        _settleReverts(pkt.sequence, 3, 0); // nothing proven yet
        _settleReverts(pkt.sequence, 1, 100);
        // a proof of what the destination does not hold is refused by the client
        vm.expectRevert("membership not proven");
        ctl.proveOutcome(pkt, _proof(receipt, OK));
        _destination(pkt, receipt, OK);
        vm.expectRevert("membership not proven"); // not this ack
        ctl.proveOutcome(pkt, _proof(receipt, ICS24Host.UNIVERSAL_ERROR_ACK));
        vm.prank(makeAddr("anyone"));
        assertEq(uint8(ctl.proveOutcome(pkt, _proof(receipt, OK))), uint8(T.Proven.Delivered));
        assertEq(uint8(ctl.sendRecord(clientId, pkt.sequence).proven), uint8(T.Proven.Delivered));
        uint256 before = usdc.balanceOf(alice);
        _settleReverts(pkt.sequence, 1, 100); // an erroneous refund of a delivered packet
        _settle(pkt.sequence, 3, 0);
        assertEq(usdc.balanceOf(alice), before);
        // proven once, and never after settlement
        vm.expectRevert(T.GnoBadProof.selector);
        ctl.proveOutcome(pkt, _proof(receipt, OK));
    }

    /// @notice An error ack: refundable. "Delivered" is refused (it would take the refund away), a refund settles it.
    function test_r4_4_errorAck_onlyRefunded() public {
        _setLimits(address(usdc), 1000, 1000, 1000);
        IICS26RouterMsgs.Packet memory pkt = _send(alice, address(usdc), 100, clientId);
        _ack(pkt, OK); // a forged success ack through the old client
        _replace();
        _destination(pkt, ctl.gnoReceipt(pkt), ICS24Host.UNIVERSAL_ERROR_ACK);
        assertEq(
            uint8(ctl.proveOutcome(pkt, _proof(ctl.gnoReceipt(pkt), ICS24Host.UNIVERSAL_ERROR_ACK))),
            uint8(T.Proven.Refundable)
        );
        vm.expectRevert(T.GnoBadProof.selector); // proven once
        ctl.proveOutcome(pkt, _proof(bytes32(0), ""));
        _settleReverts(pkt.sequence, 3, 0);
        uint256 before = usdc.balanceOf(alice);
        _settle(pkt.sequence, 1, 100);
        assertEq(usdc.balanceOf(alice), before + 100);
    }

    /// @notice A genuine refund already paid (proven error ack) is not a forged one: action 4 would book a loss that
    /// did not happen; only action 1 (zero, nothing left) settles it.
    function test_r4_4_genuineRefund_neverBookedAsForged() public {
        _setLimits(address(usdc), 1000, 1000, 1000);
        IICS26RouterMsgs.Packet memory pkt = _send(alice, address(usdc), 100, clientId);
        _errorAck(pkt); // paid at once
        _replace();
        bytes32 receipt = ctl.gnoReceipt(pkt);
        _destination(pkt, receipt, ICS24Host.UNIVERSAL_ERROR_ACK);
        ctl.proveOutcome(pkt, _proof(receipt, ICS24Host.UNIVERSAL_ERROR_ACK));
        _settleReverts(pkt.sequence, 4, 100);
        _settle(pkt.sequence, 1, 0);
        assertEq(ctl.losses(clientId, address(usdc)), 0);
    }

    /// @notice Not received: refundable only once the proven time reaches the packet's timeout (it can then never be
    /// received); a receipt present refuses the non-membership proof.
    function test_r4_4_nonReceipt_refundableAfterItsTimeout() public {
        _setLimits(address(usdc), 1000, 1000, 1000);
        IICS26RouterMsgs.Packet memory pkt = _send(alice, address(usdc), 100, clientId);
        _replace();
        lc9.setTimestamp(pkt.timeoutTimestamp - 1);
        vm.expectRevert(T.GnoBadProof.selector);
        ctl.proveOutcome(pkt, _proof(bytes32(0), ""));
        lc9.setTimestamp(pkt.timeoutTimestamp);
        assertEq(uint8(ctl.proveOutcome(pkt, _proof(bytes32(0), ""))), uint8(T.Proven.Refundable));
        _settleReverts(pkt.sequence, 3, 0);
        _settle(pkt.sequence, 1, 100);
        assertEq(usdc.balanceOf(alice), 1_000_000e6);
    }

    function test_r4_4_nonReceipt_refusedWhenReceived() public {
        _setLimits(address(usdc), 1000, 1000, 1000);
        IICS26RouterMsgs.Packet memory pkt = _send(alice, address(usdc), 100, clientId);
        _replace();
        _destination(pkt, ctl.gnoReceipt(pkt), OK);
        lc9.setTimestamp(pkt.timeoutTimestamp);
        vm.expectRevert("non-membership not proven");
        ctl.proveOutcome(pkt, _proof(bytes32(0), ""));
    }

    /// @notice A collision: another packet's receipt at the sequence (a forgery occupied it). The honest packet is
    /// refundable; "delivered" is refused.
    function test_r4_4_collision_refundsTheHonestPacket() public {
        _setLimits(address(usdc), 1000, 1000, 1000);
        IICS26RouterMsgs.Packet memory pkt = _send(alice, address(usdc), 100, clientId);
        _replace();
        bytes32 forged = keccak256("a forged packet's receipt");
        _destination(pkt, forged, "");
        assertEq(uint8(ctl.proveOutcome(pkt, _proof(forged, ""))), uint8(T.Proven.Collision));
        _settleReverts(pkt.sequence, 3, 0);
        _settle(pkt.sequence, 1, 100);
        assertEq(usdc.balanceOf(alice), 1_000_000e6);
    }

    /// @notice A forged refund (error ack through the old client, paid at once) of a delivered packet: only action 4
    /// applies, booking what was paid.
    function test_r4_4_forgedRefund_ofADeliveredPacket() public {
        _setLimits(address(usdc), 1000, 1000, 1000);
        IICS26RouterMsgs.Packet memory pkt = _send(alice, address(usdc), 100, clientId);
        _errorAck(pkt);
        _replace();
        _destination(pkt, ctl.gnoReceipt(pkt), OK);
        ctl.proveOutcome(pkt, _proof(ctl.gnoReceipt(pkt), OK));
        _settleReverts(pkt.sequence, 1, 0);
        _settle(pkt.sequence, 4, 100);
        assertEq(ctl.losses(clientId, address(usdc)), 100);
    }

    /// @notice Only a retired id's record, the record's own packet, through the replacement.
    function test_r4_4_proofRefusals() public {
        _setLimits(address(usdc), 1000, 1000, 1000);
        IICS26RouterMsgs.Packet memory pkt = _send(alice, address(usdc), 100, clientId);
        vm.expectRevert(T.GnoBadProof.selector); // not retired
        ctl.proveOutcome(pkt, _proof(bytes32(0), ""));
        _replace();
        lc9.setTimestamp(pkt.timeoutTimestamp); // a non-receipt the replacement would prove
        IICS26RouterMsgs.Packet memory other = abi.decode(abi.encode(pkt), (IICS26RouterMsgs.Packet));
        other.payloads[0].value = abi.encodePacked(other.payloads[0].value, " ");
        vm.expectRevert(T.GnoBadProof.selector); // not the record's packet
        ctl.proveOutcome(other, _proof(bytes32(0), ""));
    }

    /// @notice Through IBCAdmin: a kind 12 whose action does not match the proven outcome is spent.
    function test_r4_4_mismatchedDecision_isSpent() public {
        _setLimits(address(usdc), 1000, 1000, 1000);
        IICS26RouterMsgs.Packet memory pkt = _send(alice, address(usdc), 100, clientId);
        _replace();
        _destination(pkt, ctl.gnoReceipt(pkt), OK);
        ctl.proveOutcome(pkt, _proof(ctl.gnoReceipt(pkt), OK));
        uint64 refund = admin.lastSeq() + 1;
        assertEq(_status(_recvGov(_env(refund, S.KIND_SETTLE, P.settle1(clientId, pkt.sequence, 1, 100)))), 1);
        uint64 delivered = refund + 1;
        assertEq(_status(_recvGov(_env(delivered, S.KIND_SETTLE, P.settle1(clientId, pkt.sequence, 3, 0)))), 1);
        _skip(7 days);
        uint256 before = usdc.balanceOf(alice);
        admin.execute(refund);
        admin.execute(delivered);
        assertEq(admin.decision(admin.epoch(), refund).state, S.SPENT);
        assertEq(admin.decision(admin.epoch(), delivered).state, S.EXECUTED);
        assertEq(usdc.balanceOf(alice), before);
    }

    /// @notice A non-receipt proven before the packet's timeout is refused; the packet is then received and proven
    /// delivered. Final once proven: a later proof does not overwrite it.
    function test_r4_4_absenceBeforeDelivery_thenDelivery() public {
        _setLimits(address(usdc), 1000, 1000, 1000);
        IICS26RouterMsgs.Packet memory pkt = _send(alice, address(usdc), 100, clientId);
        _replace();
        bytes32 receipt = ctl.gnoReceipt(pkt);
        lc9.setTimestamp(pkt.timeoutTimestamp - 1); // the destination's time at the proof height
        vm.expectRevert(T.GnoBadProof.selector);
        ctl.proveOutcome(pkt, _proof(bytes32(0), ""));
        _destination(pkt, receipt, OK); // received before its timeout
        assertEq(uint8(ctl.proveOutcome(pkt, _proof(receipt, OK))), uint8(T.Proven.Delivered));
        vm.expectRevert(T.GnoBadProof.selector);
        ctl.proveOutcome(pkt, _proof(receipt, OK));
        _settleReverts(pkt.sequence, 1, 100);
        _settle(pkt.sequence, 3, 0);
    }

    /// @notice The replacement client freezing between the proof and the settlement voids the outcome: kind 12 is
    /// refused for it, all or nothing (spent through IBCAdmin), until a proof through an active client replaces it.
    function test_r4_4_verifierFrozenBeforeSettlement_voidsTheOutcome() public {
        _setLimits(address(usdc), 1000, 1000, 1000);
        IICS26RouterMsgs.Packet memory a = _send(alice, address(usdc), 100, clientId);
        IICS26RouterMsgs.Packet memory b = _send(alice, address(usdc), 200, clientId);
        _replace();
        lc9.setTimestamp(b.timeoutTimestamp);
        ctl.proveOutcome(a, _proof(bytes32(0), ""));
        ctl.proveOutcome(b, _proof(bytes32(0), ""));
        uint64 seq = admin.lastSeq() + 1;
        P.SettleItem[] memory items = new P.SettleItem[](2);
        items[0] = P.SettleItem(a.sequence, 1, 100);
        items[1] = P.SettleItem(b.sequence, 1, 200);
        assertEq(_status(_recvGov(_env(seq, S.KIND_SETTLE, P.settle(clientId, items)))), 1);
        _skip(7 days);
        lc9.setStatus(true, false); // frozen
        uint256 before = usdc.balanceOf(alice);
        admin.execute(seq);
        assertEq(admin.decision(admin.epoch(), seq).state, S.SPENT);
        assertEq(usdc.balanceOf(alice), before, "all or nothing");
        // a frozen client proves nothing new either
        vm.expectRevert(T.GnoBadProof.selector);
        ctl.proveOutcome(a, _proof(bytes32(0), ""));
        // an expired one alike
        lc9.setStatus(false, true);
        _settleReverts(a.sequence, 1, 100);
        // a verifier swap to an active client (kind 6 migrate): the void outcome is proven again through it
        MockLightClient fresh = new MockLightClient();
        IICS02ClientMsgs.CounterpartyInfo memory cp9 = router.getCounterparty("gnoland-9");
        vm.prank(address(admin));
        router.migrateClient("gnoland-9", cp9, address(fresh));
        fresh.setTimestamp(a.timeoutTimestamp);
        _settleReverts(a.sequence, 1, 100); // proven by the old verifier: void
        ctl.proveOutcome(a, _proof(bytes32(0), ""));
        _settle(a.sequence, 1, 100);
        assertEq(usdc.balanceOf(alice), before + 100);
    }
}
