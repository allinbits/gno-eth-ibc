// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IICS26RouterMsgs } from "@eureka/msgs/IICS26RouterMsgs.sol";

import { IGnoICS20ControlsTypes as T } from "../../src/interfaces/IGnoICS20Controls.sol";
import { IBCAdminExec } from "../../src/admin/IBCAdminExec.sol";
import { IBCAdminStorage as S } from "../../src/admin/IBCAdminStorage.sol";
import { GovParams as P } from "../utils/GovParams.sol";
import { MockLightClient } from "../utils/MockLightClient.sol";
import { ControlsFixture } from "./ControlsFixture.sol";

/// @notice One life of the route, end to end through the real ICS26Router: receives within and beyond the limits,
/// an Ethereum token enabled by governance, refunds paid, metered, queued, held and claimed, governance packets out
/// of order, a hand-over of the executor and a route replacement under which queued refunds and transfers go on.
contract IntegrationTest is ControlsFixture {
    function _decide(uint64 seq, uint8 kind, bytes memory params) internal returns (uint8) {
        return _status(_recvGov(_env(seq, kind, params)));
    }

    function test_lifeOfARoute() public {
        // --- gno.land -> Ethereum: within the limits minted, beyond them refused (error ack: refunded on gno.land)
        assertTrue(_isSuccessAck(_gnotIn(10_000e6, bob)));
        assertTrue(_isErrorAck(_gnotIn(GNOT_MAX + 1, bob)));
        assertEq(ugnot.balanceOf(bob), 10_000e6);

        // --- governance enables USDC (a loosening: 7 days), packets arriving out of order
        bytes memory limits = P.limits(clientId, address(usdc), 1000e6, 10_000e6, 100e6, 5000e6, 1e6);
        assertEq(_decide(2, S.KIND_SETTINGS, P.settings(clientId, 1 days)), S.STATUS_BUFFERED);
        assertEq(_decide(1, S.KIND_LIMITS, limits), S.STATUS_RECORDED); // records 1, drains 2
        assertEq(admin.lastSeq(), 2);
        _sendExpectRevert(
            alice,
            address(usdc),
            10e6,
            clientId,
            abi.encodeWithSelector(T.GnoLimitsNotSet.selector, clientId, address(usdc))
        );
        _skip(7 days);
        admin.execute(1);
        admin.execute(2);

        // --- Ethereum -> gno.land: three sends; gno.land refuses them (error acks) or they time out
        IICS26RouterMsgs.Packet memory a = _send(alice, address(usdc), 80e6, clientId);
        IICS26RouterMsgs.Packet memory b = _send(alice, address(usdc), 50e6, clientId);
        IICS26RouterMsgs.Packet memory c = _send(alice, address(usdc), 30e6, clientId);
        uint256 start = usdc.balanceOf(alice);
        _errorAck(a); // within the refund meter: paid at once
        _timeout(b); // beyond it: queued
        assertEq(usdc.balanceOf(alice), start + 80e6);
        assertEq(uint8(ctl.sendRecord(clientId, b.sequence).payment), uint8(T.Payment.Queued));

        // --- an integrity break: a watch key sets the refunds hold; refunds wait, nothing is cancelled
        vm.prank(W[0]);
        ctl.setRefundsFlag(clientId);
        _errorAck(c);
        _skip(1 days);
        vm.expectRevert(abi.encodeWithSelector(T.GnoRefundsHeld.selector, clientId));
        ctl.claim(clientId, address(usdc), 10);
        // GovDAO lifts it by an unpause of the route (24 hours, clears flags set before it)
        assertEq(_decide(3, S.KIND_UNPAUSE, P.unpause(1, clientId)), S.STATUS_RECORDED);
        _skip(1 days);
        admin.execute(3);
        assertFalse(ctl.refundsHeld(clientId));

        // --- the executor is handed over; then the route is replaced by the new executor's decisions
        IBCAdminExec next = new IBCAdminExec(address(router), d.accessManager, address(ics20));
        assertEq(_decide(4, S.KIND_HANDOVER, P.handover(address(next), address(next).codehash, "")), S.STATUS_RECORDED);
        MockLightClient lc2 = new MockLightClient();
        bytes[] memory prefix = new bytes[](2);
        prefix[0] = "main";
        prefix[1] = "/pv/vm:gno.land/r/aib/ibc/core:";
        assertEq(
            _decide(
                5, S.KIND_CLIENT, P.client(1, "gnoland-2", "ethereum-2", prefix, address(lc2), address(lc2).codehash)
            ),
            S.STATUS_RECORDED
        );
        assertEq(_decide(6, S.KIND_ROUTE, P.route(clientId, "gnoland-2")), S.STATUS_RECORDED);
        _skip(7 days);
        admin.execute(4);
        (address x,) = admin.exec();
        assertEq(x, address(next));
        admin.execute(5);
        admin.execute(6);
        assertEq(admin.epoch(), 2);
        assertEq(admin.govClient(), "gnoland-2");
        assertEq(address(router.getClient(clientId)), next.frozenClient());

        // --- the replaced route is closed: queued refunds wait for reconciliation, nothing moves
        assertTrue(ctl.routeClosed("gnoland-2"));
        vm.expectRevert(abi.encodeWithSelector(T.GnoRouteClosed.selector, "gnoland-2"));
        ctl.claim("gnoland-2", address(usdc), 10);
        assertTrue(_isErrorAck(_transferIn("gnoland-2", "ugnot", 5e6, bob)));
        // reconciliation (kind 12): b and c were never delivered, their refunds are paid by decision; then kind 13
        P.SettleItem[] memory items = new P.SettleItem[](2);
        items[0] = P.SettleItem(b.sequence, 1, 50e6);
        items[1] = P.SettleItem(c.sequence, 1, 30e6);
        assertEq(_decide(1, S.KIND_SETTLE, P.settle(clientId, items)), S.STATUS_RECORDED);
        assertEq(_decide(2, S.KIND_REOPEN, P.reopen("gnoland-2")), S.STATUS_RECORDED);
        _skip(7 days);
        admin.execute(1);
        admin.execute(2);
        assertEq(usdc.balanceOf(alice), start + 160e6);
        assertEq(uint8(ctl.sendRecord(clientId, b.sequence).settlement), 1);
        // the settled entries leave the queue without a second payment
        assertEq(ctl.claim("gnoland-2", address(usdc), 10), 2);
        assertEq(usdc.balanceOf(alice), start + 160e6);

        // --- transfers and governance go on over the new client
        assertTrue(_isSuccessAck(_transferIn("gnoland-2", "ugnot", 5e6, bob)));
        IICS26RouterMsgs.Packet memory e = _send(alice, address(usdc), 10e6, "gnoland-2");
        _errorAck(e);
        assertEq(usdc.balanceOf(alice), start + 160e6);
        assertEq(_decide(3, S.KIND_SETTINGS, P.settings("gnoland-2", 14 days)), S.STATUS_RECORDED);
        assertEq(ctl.quarantineSeconds("gnoland-2"), 14 days);
        assertEq(ctl.quarantineSeconds(clientId), 14 days, "one route, two ids");
    }
}
