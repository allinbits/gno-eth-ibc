// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IIBCAdmin } from "../../src/interfaces/IIBCAdmin.sol";
import { IBCAdminStorage as S } from "../../src/admin/IBCAdminStorage.sol";
import { IBCAdminExec } from "../../src/admin/IBCAdminExec.sol";
import { IBCAdminNative } from "../../src/admin/IBCAdminNative.sol";
import { IBCAdmin } from "../../src/admin/IBCAdmin.sol";
import { GovParams as P } from "../utils/GovParams.sol";
import { MockLightClient } from "../utils/MockLightClient.sol";
import { ControlsFixture } from "./ControlsFixture.sol";

/// @notice An executor bound as IBCAdmin's that attacks the permanent disable from inside its own frames (it runs as
/// IBCAdmin, with IBCAdmin's storage and authority), at recording (`mode` 1) or at execution (`mode` 2), else
/// honest (wait at recording, done at execution):
/// - trace (a): it executes the pending kind 14 `disableSeq` itself, from inside the frame (when non-zero);
/// - then it zeroes every storage word a disabled bit could live in (IBCAdmin's slot 0, the layout's next free one);
/// - trace (b): it fakes an open, mature proposal and re-enters the guardians' entry points, reporting their answers
///   (`Probe`), then restores the proposal state.
/// Its recovery module is itself; reaching it would open a proposal.
contract ReenablingExec {
    event Probe(bytes4 approve, bytes4 execute, bool disabled);

    address internal immutable r;
    address internal immutable am;
    address internal immutable t;
    uint256 internal immutable mode;
    uint64 internal immutable disableSeq;

    constructor(address r_, address am_, address t_, uint256 mode_, uint64 disableSeq_) {
        (r, am, t, mode, disableSeq) = (r_, am_, t_, mode_, disableSeq_);
    }

    function bindings() external view returns (address, address, address) {
        return (r, am, t);
    }

    function recoveryModule() external view returns (address) {
        return address(this);
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function RECOVERY_HASH() external view returns (bytes32) {
        return address(this).codehash;
    }

    function atRecording(uint8, uint64, bytes calldata, bool) external returns (uint8, string memory) {
        if (mode == 1) _attack();
        return (S.WAIT, "");
    }

    function run(uint8, uint64, bytes calldata, uint64) external returns (string memory) {
        if (mode == 2) _attack();
        return "";
    }

    function _attack() private {
        if (disableSeq != 0) IBCAdmin(address(this)).execute(disableSeq);
        // solhint-disable-next-line no-inline-assembly
        assembly {
            sstore(0, 0)
            sstore(add(0xc7b243561409e24cdf9051e7d85f7a9f9509cfb6b2d07b504ea2d9365e700c00, 42), 0)
        }
        S.Layout storage l = S.layout();
        (l.recovery.proposal, l.recovery.openedAt) = (bytes32(uint256(1)), 1);
        IIBCAdmin.RecoveryProposal memory p;
        bytes4 a = _try(abi.encodeCall(IBCAdmin.approveRecovery, (p)));
        bytes4 e = _try(abi.encodeCall(IBCAdmin.executeRecovery, ()));
        (l.recovery.proposal, l.recovery.openedAt) = (bytes32(0), 0);
        emit Probe(a, e, IBCAdmin(address(this)).recoveryDisabled());
    }

    function _try(bytes memory call) private returns (bytes4) {
        (bool ok, bytes memory ret) = address(this).call(call);
        return ok || ret.length < 4 ? bytes4(0) : bytes4(ret);
    }

    /// @notice The "recovery module": anything reaching it opens a proposal.
    fallback() external {
        S.layout().recovery.openedAt = uint64(block.timestamp);
    }
}

/// @notice Kind 14 (ADR pr6375 §5.4, §7.12): gno.land's governed, permanent disable of the emergency recovery,
/// enabled at launch. A 7-day kind deferred by flags and holds and suspended while a proposal is open; once applied,
/// nothing opens or executes a recovery again, pending approvals are gone, and no executor can switch it back on.
contract RecoveryDisableTest is ControlsFixture {
    uint64 internal constant DELAY = 30 days;
    event Probe(bytes4 approve, bytes4 execute, bool disabled);

    MockLightClient internal attested;

    function _recovery() internal pure override returns (IIBCAdmin.RecoveryConfig memory) {
        return IIBCAdmin.RecoveryConfig({
            delay: DELAY, threshold: 3, cancelThreshold: 3, silence: 30 days, holdPeriod: 14 days
        });
    }

    function setUp() public override {
        super.setUp();
        attested = new MockLightClient();
        // gno.land binds: IBCAdmin records its first decision
        assertEq(_status(_recvGov(_env(1, S.KIND_SETTINGS, P.settings(clientId, 7 days)))), S.STATUS_RECORDED);
    }

    function _proposal() internal view returns (IIBCAdmin.RecoveryProposal memory p) {
        bytes[] memory prefix = new bytes[](2);
        prefix[0] = "main";
        prefix[1] = "/pv/vm:gno.land/r/aib/ibc/core:";
        p = IIBCAdmin.RecoveryProposal({
            newClientId: "gnoland-7",
            counterpartyClientId: "ethereum-7",
            merklePrefix: prefix,
            lightClient: address(attested),
            codeHash: address(attested).codehash,
            suspectFrom: 0
        });
    }

    function _approve(uint256 seat) internal {
        vm.prank(G[seat]);
        admin.approveRecovery(_proposal());
    }

    function _openedAt() internal view returns (uint64 openedAt) {
        (, openedAt,,) = admin.recovery();
    }

    function _open() internal {
        lc.setStatus(true, false);
        _approve(0);
        _approve(1);
        _approve(2);
        assertTrue(_openedAt() != 0, "open");
    }

    /// @notice Records a kind 14 over the current client; returns its number.
    function _recordDisable() internal returns (uint64 seq) {
        seq = admin.lastSeq() + 1;
        assertEq(
            _status(_recvGov(_env(seq, S.KIND_DISABLE_RECOVERY, P.disableRecovery(admin.govClient())))),
            S.STATUS_RECORDED
        );
        assertEq(admin.decision(admin.epoch(), seq).state, S.PENDING);
    }

    function _disable() internal returns (uint64 seq) {
        seq = _recordDisable();
        _skip(S.WEEK);
        admin.execute(seq);
        assertTrue(admin.recoveryDisabled());
    }

    function _handover(address x) internal {
        uint64 seq = admin.lastSeq() + 1;
        assertEq(_status(_recvGov(_env(seq, S.KIND_HANDOVER, P.handover(x, x.codehash, "")))), S.STATUS_RECORDED);
        _skip(S.WEEK);
        admin.execute(seq);
        (address now_,) = admin.exec();
        assertEq(now_, x, "handed over");
    }

    // ------------------------------------------------------------------------------------------------- latch --

    /// @notice The latch is IBCAdminNative's own storage: only IBCAdmin sets it, directly; nobody else, and a
    /// delegated call cannot even read it.
    function test_latch_onlyIBCAdmin() public {
        IBCAdminNative n = IBCAdminNative(admin.native());
        assertFalse(n.recoveryDisabledLatched(), "enabled at launch");
        vm.prank(alice);
        vm.expectRevert(IIBCAdmin.NotSelf.selector);
        n.latch();
        vm.prank(G[0]);
        vm.expectRevert(IIBCAdmin.NotSelf.selector);
        n.latch();
        _disable();
        assertTrue(n.recoveryDisabledLatched());
    }

    // ------------------------------------------------------------------------------------------------ the kind --

    /// @notice Recorded and executed like the other 7-day kinds: it waits its 7 days, then the recovery is off for
    /// good, every pending approval cleared, and every way into a recovery refused with a clear error.
    function test_disable_lifecycle() public {
        assertFalse(admin.recoveryDisabled(), "on at launch");
        _approve(0);
        _approve(1); // two approvals: below the threshold, and the route is healthy
        uint64 seq = _recordDisable();
        assertEq(admin.decision(1, seq).kind, 14);
        _skip(S.WEEK - 1);
        vm.expectRevert(abi.encodeWithSelector(IIBCAdmin.NotMature.selector, uint64(_now() + 1)));
        admin.execute(seq);
        _skip(1);
        vm.expectEmit(true, true, false, false, address(admin));
        emit IIBCAdmin.EmergencyRecoveryDisabled(1, seq);
        vm.prank(bob); // anyone
        admin.execute(seq);
        assertEq(admin.decision(1, seq).state, S.EXECUTED);
        assertTrue(admin.recoveryDisabled());
        (bytes32 proposal, uint64 openedAt, uint8 cancels, bytes32[4] memory approved) = admin.recovery();
        assertEq(proposal, bytes32(0));
        assertEq(openedAt, 0);
        assertEq(cancels, 0);
        for (uint256 i = 0; i < 4; i++) {
            assertEq(approved[i], bytes32(0), "approvals cleared");
        }
        // nothing opens or executes a recovery any more, even on an eligible route
        lc.setStatus(true, false);
        for (uint256 g = 0; g < 4; g++) {
            vm.prank(G[g]);
            vm.expectRevert(IIBCAdmin.RecoveryPermanentlyDisabled.selector);
            admin.approveRecovery(_proposal());
        }
        vm.expectRevert(IIBCAdmin.RecoveryPermanentlyDisabled.selector);
        admin.executeRecovery();
        // the native paths stay safe: a cancellation finds nothing open, the block lift nothing to lift
        vm.prank(G[0]);
        admin.cancelRecovery();
        admin.clearRecoveryBlock();
        assertFalse(ctl.recoveryBlocked(clientId));
        assertEq(_openedAt(), 0);
        // the recovery config stays readable; governance goes on as before
        assertEq(admin.recoveryConfig().delay, DELAY);
        lc.setStatus(false, false);
        uint64 next = admin.lastSeq() + 1;
        assertEq(_status(_recvGov(_env(next, S.KIND_SETTINGS, P.settings(clientId, 1 days)))), S.STATUS_RECORDED);
        _skip(S.WEEK);
        admin.execute(next);
        assertEq(admin.decision(1, next).state, S.EXECUTED);
    }

    /// @notice Deferred by a flag and by a hold, like every 7-day kind; it lands once they are gone.
    function test_deferredByFlagsAndHolds() public {
        uint64 seq = _recordDisable();
        _skip(S.WEEK);
        vm.prank(W[0]);
        admin.setFlag();
        vm.expectRevert(IIBCAdmin.Deferred.selector);
        admin.execute(seq);
        vm.prank(G[0]);
        admin.setFlag();
        vm.prank(G[1]);
        admin.setFlag(); // a hold
        _skip(30 days);
        vm.expectRevert(IIBCAdmin.Deferred.selector);
        admin.execute(seq);
        vm.prank(W[0]);
        admin.clearFlag();
        vm.prank(G[0]);
        admin.clearFlag();
        vm.prank(G[1]);
        admin.clearFlag();
        vm.expectRevert(IIBCAdmin.Deferred.selector);
        admin.execute(seq); // the hold's dip grace
        _skip(S.DAY);
        admin.execute(seq);
        assertTrue(admin.recoveryDisabled());
    }

    /// @notice While a proposal is open, the disable waits (suspended, still pending); once the guardians cancel the
    /// proposal, it applies.
    function test_waitsWhileARecoveryIsOpen_thenAppliesAfterACancel() public {
        _open();
        uint64 seq = _recordDisable(); // recorded while open: it waits
        _skip(S.WEEK);
        vm.expectRevert(IIBCAdmin.Suspended.selector);
        admin.execute(seq);
        assertEq(admin.decision(1, seq).state, S.PENDING);
        for (uint256 g = 0; g < 3; g++) {
            vm.prank(G[g]);
            admin.cancelRecovery();
        }
        assertEq(_openedAt(), 0, "cancelled");
        admin.execute(seq);
        assertTrue(admin.recoveryDisabled());
    }

    /// @notice A recovery that executes first switches the epoch, which abandons the pending disable with the rest of
    /// the old epoch; gno.land sends it again over the new client, and it applies there.
    function test_anExecutedRecoveryAbandonsIt_resentInTheNewEpoch() public {
        _open();
        uint64 seq = _recordDisable();
        _skip(DELAY);
        admin.executeRecovery();
        assertEq(admin.epoch(), 2);
        vm.expectRevert(abi.encodeWithSelector(IIBCAdmin.NotPending.selector, seq));
        admin.execute(seq);
        assertFalse(admin.recoveryDisabled());
        // the old client's id names nothing in epoch 2: spent
        assertEq(_status(_recvGov(_env(1, S.KIND_DISABLE_RECOVERY, P.disableRecovery(clientId)))), S.STATUS_SPENT);
        assertEq(_status(_recvGov(_env(2, S.KIND_DISABLE_RECOVERY, P.disableRecovery("gnoland-7")))), S.STATUS_RECORDED);
        _skip(S.WEEK);
        admin.execute(2);
        assertTrue(admin.recoveryDisabled());
    }

    /// @notice A second disable is refused and spent ("disabled"), whether it was recorded before the first applied
    /// (at execution) or after (at recording).
    function test_secondDisable_spent() public {
        uint64 a = _recordDisable();
        uint64 b = _recordDisable();
        _skip(S.WEEK);
        admin.execute(a);
        vm.expectEmit(true, true, false, true, address(admin));
        emit IIBCAdmin.DecisionSpent(1, b, 14, "disabled");
        admin.execute(b);
        assertEq(admin.decision(1, b).state, S.SPENT);
        uint64 c = admin.lastSeq() + 1;
        vm.expectEmit(true, true, false, true, address(admin));
        emit IIBCAdmin.DecisionSpent(1, c, 14, "disabled");
        assertEq(_status(_recvGov(_env(c, S.KIND_DISABLE_RECOVERY, P.disableRecovery(clientId)))), S.STATUS_SPENT);
        assertTrue(admin.recoveryDisabled());
    }

    /// @notice The parameters exactly the canonical `abi.encode(string clientId)` of the epoch's client; anything else
    /// is spent at recording, and never reverts the delivery.
    function test_params_spentAtRecording() public {
        bytes memory good = P.disableRecovery(clientId);
        bytes[6] memory bad = [
            P.disableRecovery("client-9"), // another client
            P.disableRecovery(""),
            bytes.concat(good, bytes32(0)), // trailing data
            abi.encode(uint256(64), uint256(0)), // another offset
            abi.encode(uint256(32), uint256(1000)), // longer than the bytes
            bytes("") // no params
        ];
        string[6] memory why = ["client", "client", "params", "params", "params", "params"];
        bytes memory dirty = good;
        dirty[dirty.length - 1] = 0x01; // dirty padding
        for (uint256 i = 0; i < 7; i++) {
            uint64 seq = admin.lastSeq() + 1;
            bytes memory p = i < 6 ? bad[i] : dirty;
            vm.expectEmit(true, true, false, true, address(admin));
            emit IIBCAdmin.DecisionSpent(1, seq, 14, i < 6 ? why[i] : "params");
            assertEq(_status(_recvGov(_env(seq, S.KIND_DISABLE_RECOVERY, p))), S.STATUS_SPENT);
        }
        assertFalse(admin.recoveryDisabled());
    }

    // ------------------------------------------------------------------------------------- one-way, upgrades --

    function _bad(uint256 mode, uint64 disableSeq) internal returns (ReenablingExec) {
        return new ReenablingExec(address(router), d.accessManager, address(ics20), mode, disableSeq);
    }

    function _expectProbe() internal {
        vm.expectEmit(false, false, false, true, address(admin));
        emit Probe(IIBCAdmin.RecoveryPermanentlyDisabled.selector, IIBCAdmin.RecoveryPermanentlyDisabled.selector, true);
    }

    /// @notice The guardians' entry points stay closed after any executor frame: approvals and execution refused.
    function _closed() internal {
        assertTrue(admin.recoveryDisabled());
        assertEq(_openedAt(), 0);
        lc.setStatus(true, false);
        vm.prank(G[0]);
        vm.expectRevert(IIBCAdmin.RecoveryPermanentlyDisabled.selector);
        admin.approveRecovery(_proposal());
        vm.expectRevert(IIBCAdmin.RecoveryPermanentlyDisabled.selector);
        admin.executeRecovery();
        lc.setStatus(false, false);
    }

    /// @notice Records a hand-over to `x` and a kind 14 right behind it; returns the kind 14's number.
    function _handoverThenDisable(function(uint64) internal returns (ReenablingExec) make)
        internal
        returns (uint64 disableSeq)
    {
        uint64 h = admin.lastSeq() + 1;
        disableSeq = h + 1;
        ReenablingExec x = make(disableSeq);
        assertEq(_status(_recvGov(_env(h, S.KIND_HANDOVER, P.handover(address(x), address(x).codehash, "")))), 1);
        assertEq(
            _status(_recvGov(_env(disableSeq, S.KIND_DISABLE_RECOVERY, P.disableRecovery(clientId)))), S.STATUS_RECORDED
        );
        _skip(S.WEEK);
        admin.execute(h);
        (address now_,) = admin.exec();
        assertEq(now_, address(x), "handed over");
    }

    function _atRecording(uint64 seq) internal returns (ReenablingExec) {
        return _bad(1, seq);
    }

    function _atExecution(uint64 seq) internal returns (ReenablingExec) {
        return _bad(2, seq);
    }

    /// @notice Trace (a) at recording: the executor applies the pending kind 14 from inside its recording frame, then
    /// zeroes IBCAdmin's storage and re-enters the guardians' entry points with a faked proposal: the latch, in
    /// IBCAdminNative's storage, holds, and both entry points refuse, inside the frame and after.
    function test_traceA_nestedDisableThenClear_atRecording() public {
        uint64 disableSeq = _handoverThenDisable(_atRecording);
        assertFalse(admin.recoveryDisabled());
        _expectProbe();
        assertEq(
            _status(_recvGov(_env(disableSeq + 1, S.KIND_SETTINGS, P.settings(clientId, 2 days)))), S.STATUS_RECORDED
        );
        assertEq(admin.decision(1, disableSeq).state, S.EXECUTED, "the nested disable applied");
        _closed();
    }

    /// @notice Trace (a) at execution: the same, from inside an execution frame.
    function test_traceA_nestedDisableThenClear_atExecution() public {
        uint64 disableSeq = _handoverThenDisable(_atExecution);
        uint64 seq = disableSeq + 1;
        assertEq(_status(_recvGov(_env(seq, S.KIND_UNPAUSE, P.unpause(2, "")))), S.STATUS_RECORDED);
        _skip(S.DAY);
        _expectProbe();
        admin.execute(seq);
        assertEq(admin.decision(1, seq).state, S.EXECUTED);
        assertEq(admin.decision(1, disableSeq).state, S.EXECUTED, "the nested disable applied");
        _closed();
    }

    /// @notice Trace (b) at recording, after a disable: a temporary clear and a re-entry into `executeRecovery` with a
    /// faked open proposal are refused.
    function test_traceB_temporaryClearThenReentry_atRecording() public {
        _disable();
        _handover(address(_bad(1, 0)));
        _expectProbe();
        uint64 seq = admin.lastSeq() + 1;
        assertEq(_status(_recvGov(_env(seq, S.KIND_SETTINGS, P.settings(clientId, 2 days)))), S.STATUS_RECORDED);
        _closed();
    }

    /// @notice Trace (b) at execution.
    function test_traceB_temporaryClearThenReentry_atExecution() public {
        _disable();
        _handover(address(_bad(2, 0)));
        uint64 seq = admin.lastSeq() + 1;
        assertEq(_status(_recvGov(_env(seq, S.KIND_UNPAUSE, P.unpause(2, "")))), S.STATUS_RECORDED);
        _skip(S.DAY);
        _expectProbe();
        admin.execute(seq);
        assertEq(admin.decision(1, seq).state, S.EXECUTED);
        _closed();
        // an honest executor afterwards changes nothing
        IBCAdminExec good = new IBCAdminExec(address(router), d.accessManager, address(ics20));
        _handover(address(good));
        _closed();
    }

    /// @notice An executor whose recovery module would switch the recovery on: IBCAdmin refuses before the module is
    /// reached, so neither an approval nor an execution runs it.
    function test_maliciousRecoveryModule_neverReached() public {
        _disable();
        ReenablingExec bad = _bad(0, 0);
        _handover(address(bad));
        lc.setStatus(true, false);
        vm.prank(G[0]);
        vm.expectRevert(IIBCAdmin.RecoveryPermanentlyDisabled.selector);
        admin.approveRecovery(_proposal());
        vm.expectRevert(IIBCAdmin.RecoveryPermanentlyDisabled.selector);
        admin.executeRecovery();
        assertTrue(admin.recoveryDisabled());
        assertEq(_openedAt(), 0);
    }
}

/// @notice A deployment that never enabled the recovery starts latched: kind 14 is spent ("disabled"), and
/// the recovery's entry points keep their original error.
contract RecoveryNeverEnabledTest is ControlsFixture {
    function test_offFromTheStart() public {
        assertTrue(admin.recoveryDisabled());
        assertEq(admin.recoveryConfig().delay, 0);
        vm.expectEmit(true, true, false, true, address(admin));
        emit IIBCAdmin.DecisionSpent(1, 1, 14, "disabled");
        assertEq(_status(_recvGov(_env(1, S.KIND_DISABLE_RECOVERY, P.disableRecovery(clientId)))), S.STATUS_SPENT);
        IIBCAdmin.RecoveryProposal memory p;
        vm.prank(G[0]);
        vm.expectRevert(IIBCAdmin.RecoveryDisabled.selector);
        admin.approveRecovery(p);
    }
}
