// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IICS26RouterMsgs } from "@eureka/msgs/IICS26RouterMsgs.sol";

import { IAccessManager } from "@openzeppelin-contracts/access/manager/IAccessManager.sol";
import { IBCRolesLib } from "@eureka/utils/IBCRolesLib.sol";

import { IIBCAdmin } from "../../src/interfaces/IIBCAdmin.sol";
import { IBCAdminExec } from "../../src/admin/IBCAdminExec.sol";
import { IBCAdminStorage as S } from "../../src/admin/IBCAdminStorage.sol";
import { GovParams as P } from "../utils/GovParams.sol";
import { MockLightClient } from "../utils/MockLightClient.sol";
import { ControlsFixture } from "./ControlsFixture.sol";

/// @notice The emergency route replacement is off unless the deployment enables it (ADR §7.12).
contract IBCAdminRecoveryDisabledTest is ControlsFixture {
    function test_disabledByDefault() public {
        IIBCAdmin.RecoveryProposal memory p;
        vm.prank(G[0]);
        vm.expectRevert(IIBCAdmin.RecoveryDisabled.selector);
        admin.approveRecovery(p);
        vm.prank(G[0]);
        vm.expectRevert(IIBCAdmin.RecoveryDisabled.selector);
        admin.cancelRecovery();
        vm.expectRevert(IIBCAdmin.RecoveryDisabled.selector);
        admin.executeRecovery();
        assertEq(admin.recoveryConfig().delay, 0);
    }
}

/// @notice The emergency route replacement, enabled: a guardian supermajority's proposal of an attested client opens
/// only while the route is eligible, blocks token receives and suspends the authority-changing kinds while open,
/// can be cancelled only by guardians, and executes after the long delay as a route replacement (§7.12).
contract IBCAdminRecoveryTest is ControlsFixture {
    uint64 internal constant DELAY = 30 days;
    MockLightClient internal attested;

    function _recovery() internal pure override returns (IIBCAdmin.RecoveryConfig memory) {
        return IIBCAdmin.RecoveryConfig({
            delay: DELAY, threshold: 3, cancelThreshold: 3, silence: 30 days, holdPeriod: 14 days
        });
    }

    function setUp() public override {
        super.setUp();
        attested = new MockLightClient();
    }

    function _proposal(string memory id) internal view returns (IIBCAdmin.RecoveryProposal memory p) {
        bytes[] memory prefix = new bytes[](2);
        prefix[0] = "main";
        prefix[1] = "/pv/vm:gno.land/r/aib/ibc/core:";
        p = IIBCAdmin.RecoveryProposal({
            newClientId: id,
            counterpartyClientId: "ethereum-7",
            merklePrefix: prefix,
            lightClient: address(attested),
            codeHash: address(attested).codehash,
            suspectFrom: 0
        });
    }

    function _approve(uint256 seat, IIBCAdmin.RecoveryProposal memory p) internal {
        vm.prank(G[seat]);
        admin.approveRecovery(p);
    }

    function _openedAt() internal view returns (uint64 openedAt) {
        (, openedAt,,) = admin.recovery();
    }

    function _openFrozen() internal returns (IIBCAdmin.RecoveryProposal memory p) {
        p = _proposal("gnoland-7");
        lc.setStatus(true, false);
        _approve(0, p);
        _approve(1, p);
        _approve(2, p);
        assertEq(_openedAt(), _now());
    }

    function test_onlyGuardianSeats() public {
        IIBCAdmin.RecoveryProposal memory p = _proposal("gnoland-7");
        vm.prank(alice);
        vm.expectRevert(IIBCAdmin.NotGuardian.selector);
        admin.approveRecovery(p);
        vm.prank(W[0]); // watch keys cannot
        vm.expectRevert(IIBCAdmin.NotGuardian.selector);
        admin.approveRecovery(p);
    }

    function test_opensOnlyWhenEligible() public {
        IIBCAdmin.RecoveryProposal memory p = _proposal("gnoland-7");
        _approve(0, p);
        _approve(1, p);
        _approve(2, p);
        assertEq(_openedAt(), 0, "a healthy, live route is not eligible");
        lc.setStatus(false, true); // expired
        _approve(2, p); // calling again re-checks
        assertEq(_openedAt(), _now());
    }

    function test_eligibleAfterSilence() public {
        IIBCAdmin.RecoveryProposal memory p = _proposal("gnoland-7");
        _recvGov(_env(1, S.KIND_SETTINGS, P.settings(clientId, 1 days)));
        _skip(30 days - 1);
        _approve(0, p);
        _approve(1, p);
        _approve(2, p);
        assertEq(_openedAt(), 0);
        _skip(1);
        _approve(0, p);
        assertTrue(_openedAt() != 0);
    }

    function test_eligibleAfterALongHold() public {
        IIBCAdmin.RecoveryProposal memory p = _proposal("gnoland-7");
        vm.prank(G[2]);
        admin.setFlag();
        vm.prank(G[3]);
        admin.setFlag();
        _recvGov(_env(1, S.KIND_SETTINGS, P.settings(clientId, 1 days))); // the channel is alive
        _skip(14 days);
        _approve(0, p);
        _approve(1, p);
        _approve(2, p);
        assertTrue(_openedAt() != 0);
    }

    function test_approvalsOfDifferentProposalsDoNotAdd() public {
        lc.setStatus(true, false);
        _approve(0, _proposal("gnoland-7"));
        _approve(1, _proposal("gnoland-7"));
        _approve(2, _proposal("gnoland-8"));
        assertEq(_openedAt(), 0);
        _approve(3, _proposal("gnoland-7"));
        assertTrue(_openedAt() != 0);
        vm.expectRevert(IIBCAdmin.RecoveryState.selector);
        _approve(2, _proposal("gnoland-8"));
    }

    function test_replacedSeat_losesItsApproval() public {
        IIBCAdmin.RecoveryProposal memory p = _proposal("gnoland-7");
        _approve(0, p);
        _approve(1, p);
        address fresh = makeAddr("fresh guardian");
        _recvGov(_env(admin.lastSeq() + 1, S.KIND_SEATS, P.seat1(1, fresh)));
        _skip(7 days);
        admin.execute(admin.lastSeq());
        lc.setStatus(true, false);
        _approve(2, p);
        assertEq(_openedAt(), 0, "seat 1's approval left with its key");
        vm.prank(fresh);
        admin.approveRecovery(p);
        assertTrue(_openedAt() != 0);
    }

    /// @notice #10: a revocation buffered before the recovery opened, drained while it is open, waits; it is due at
    /// once when the recovery is cancelled.
    function test_revocationDrainedDuringRecovery_waits() public {
        IAccessManager am = IAccessManager(d.accessManager);
        vm.prank(address(admin));
        am.grantRole(IBCRolesLib.RELAYER_ROLE, alice, 0);
        uint64 next = admin.lastSeq() + 1;
        _recvGov(_env(next + 1, S.KIND_ROLE, P.role(false, IBCRolesLib.RELAYER_ROLE, alice))); // buffered
        _openFrozen();
        _recvGov(_env(next, S.KIND_SETTINGS, P.settings(clientId, 14 days))); // fills the gap, drains the revoke
        assertEq(admin.decision(1, next + 1).state, S.PENDING);
        (bool has,) = am.hasRole(IBCRolesLib.RELAYER_ROLE, alice);
        assertTrue(has, "not revoked while the recovery is open");
        vm.expectRevert(IIBCAdmin.Suspended.selector);
        admin.execute(next + 1);
        vm.prank(G[0]);
        admin.cancelRecovery();
        vm.prank(G[1]);
        admin.cancelRecovery();
        vm.prank(G[2]);
        admin.cancelRecovery();
        admin.execute(next + 1); // a revocation: due at once, never deferred
        (has,) = am.hasRole(IBCRolesLib.RELAYER_ROLE, alice);
        assertFalse(has);
    }

    /// @notice #11: the attested client must follow gno.land's chain and still be usable when the recovery executes.
    function test_attestedClient_sameChain_usableAtExecution() public {
        lc.setStatus(true, false);
        attested.setChainId("other-chain");
        vm.prank(G[0]);
        vm.expectRevert(IIBCAdmin.RecoveryState.selector);
        admin.approveRecovery(_proposal("gnoland-7"));
        attested.setChainId("gno-test");
        _openFrozen();
        _skip(DELAY);
        attested.setStatus(false, true); // expired during the delay
        vm.expectRevert(IIBCAdmin.RecoveryState.selector);
        admin.executeRecovery();
        attested.setStatus(false, false);
        admin.executeRecovery();
        assertEq(admin.epoch(), 2);
    }

    function test_whileOpen_receivesBlocked_authorityKindsSuspended() public {
        uint64 seats = admin.lastSeq() + 1;
        _recvGov(_env(seats, S.KIND_SEATS, P.seat1(0, makeAddr("fresh"))));
        uint64 settings = seats + 1;
        _recvGov(_env(settings, S.KIND_SETTINGS, P.settings(clientId, 1 days)));
        _openFrozen();
        assertTrue(ctl.recoveryBlocked(clientId));
        assertTrue(_isErrorAck(_gnotIn(1, bob)));
        _skip(7 days);
        vm.expectRevert(IIBCAdmin.Suspended.selector);
        admin.execute(seats);
        admin.execute(settings); // not an authority change
        assertEq(ctl.quarantineSeconds(clientId), 1 days);
    }

    function test_cancelledByGuardians_only() public {
        _openFrozen();
        vm.prank(G[0]);
        admin.cancelRecovery();
        vm.prank(G[1]);
        admin.cancelRecovery();
        vm.prank(W[0]);
        vm.expectRevert(IIBCAdmin.NotGuardian.selector);
        admin.cancelRecovery();
        assertTrue(_openedAt() != 0);
        vm.prank(G[3]);
        admin.cancelRecovery();
        assertEq(_openedAt(), 0);
        assertFalse(ctl.recoveryBlocked(clientId));
        lc.setStatus(false, false);
        assertTrue(_isSuccessAck(_gnotIn(1, bob)));
    }

    function test_executesAfterTheDelay_asARouteReplacement() public {
        _setLimits(address(usdc), 1000, 1000, 1000);
        IICS26RouterMsgs.Packet memory inFlight = _send(alice, address(usdc), 100, clientId);
        uint64 stale = admin.lastSeq() + 1;
        _recvGov(_env(stale, S.KIND_SETTINGS, P.settings(clientId, 1 days)));
        _openFrozen();
        _skip(DELAY - 1);
        vm.expectRevert();
        admin.executeRecovery();
        _skip(1);
        vm.prank(bob); // anyone
        admin.executeRecovery();

        assertEq(admin.epoch(), 2);
        assertEq(admin.govClient(), "gnoland-7");
        assertEq(address(router.getClient("gnoland-7")), address(attested));
        assertEq(router.getCounterparty("gnoland-7").clientId, "ethereum-7");
        assertEq(address(router.getClient(clientId)), IBCAdminExec(d.ibcAdminExec).frozenClient());
        assertEq(ctl.routeKey("gnoland-7"), clientId);
        assertFalse(ctl.recoveryBlocked("gnoland-7"));
        assertEq(_openedAt(), 0);
        vm.expectRevert(abi.encodeWithSelector(IIBCAdmin.NotPending.selector, stale));
        admin.execute(stale);
        // the replaced route stays closed: the packet in flight on the frozen id is reconciled by decision (kind 12:
        // not delivered, refunded), then the route reopens (kind 13)
        assertTrue(ctl.routeClosed("gnoland-7"));
        assertTrue(_isErrorAck(_transferIn("gnoland-7", "ugnot", 5, bob)));
        uint256 before = usdc.balanceOf(alice);
        assertEq(
            _status(_recvGov(_env(1, S.KIND_SETTLE, P.settle1(clientId, inFlight.sequence, 1, 100)))), S.STATUS_RECORDED
        );
        assertEq(_status(_recvGov(_env(2, S.KIND_REOPEN, P.reopen("gnoland-7")))), S.STATUS_RECORDED);
        _skip(7 days);
        admin.execute(1);
        admin.execute(2);
        assertEq(usdc.balanceOf(alice), before + 100);
        assertTrue(_isSuccessAck(_transferIn("gnoland-7", "ugnot", 5, bob)));
        assertEq(_status(_recvGov(_env(3, S.KIND_SETTINGS, P.settings("gnoland-7", 1 days)))), S.STATUS_RECORDED);
    }

    function test_executeRefusesAClientWithAnotherCode() public {
        _openFrozen();
        vm.etch(address(attested), address(new IBCAdminExec(address(router), d.accessManager, address(ics20))).code);
        _skip(DELAY);
        vm.expectRevert(IIBCAdmin.RecoveryState.selector);
        admin.executeRecovery();
    }
}
