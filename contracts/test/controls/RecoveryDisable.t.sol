// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IIBCAdmin } from "../../src/interfaces/IIBCAdmin.sol";
import { IBCAdminStorage as S } from "../../src/admin/IBCAdminStorage.sol";
import { IBCAdminExec } from "../../src/admin/IBCAdminExec.sol";
import { GovParams as P } from "../utils/GovParams.sol";
import { MockLightClient } from "../utils/MockLightClient.sol";
import { ControlsFixture } from "./ControlsFixture.sol";

/// @notice Where IBCAdminStorage puts the disabled bit: a contract with only that layout, read slot by slot.
contract LayoutProbe {
    function setBit() external {
        S.layout().recoveryDisabled = true;
    }
}

/// @notice An executor bound as IBCAdmin's that tries to switch a disabled recovery back on by writing IBCAdmin's
/// storage (it runs as IBCAdmin): `mode` 1 at recording, 2 at execution, 3 opens a proposal at execution. Every other
/// answer is an honest one (wait at recording, done at execution). Its recovery module is itself, and would open a
/// proposal if it were ever reached.
contract ReenablingExec {
    address internal immutable r;
    address internal immutable am;
    address internal immutable t;
    uint256 internal immutable mode;

    constructor(address r_, address am_, address t_, uint256 mode_) {
        (r, am, t, mode) = (r_, am_, t_, mode_);
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
        if (mode == 1) S.layout().recoveryDisabled = false;
        return (S.WAIT, "");
    }

    function run(uint8, uint64, bytes calldata, uint64) external returns (string memory) {
        if (mode == 2) S.layout().recoveryDisabled = false;
        if (mode == 3) S.layout().recovery.openedAt = uint64(block.timestamp);
        return "";
    }

    /// @notice The "recovery module": anything reaching it switches the recovery on and opens a proposal.
    fallback() external {
        S.Layout storage l = S.layout();
        l.recoveryDisabled = false;
        l.recovery.openedAt = uint64(block.timestamp);
    }
}

/// @notice Kind 14 (ADR pr6375 §5.4, §7.12): gno.land's governed, permanent disable of the emergency recovery,
/// enabled at launch. A 7-day kind deferred by flags and holds and suspended while a proposal is open; once applied,
/// nothing opens or executes a recovery again, pending approvals are gone, and no executor can switch it back on.
contract RecoveryDisableTest is ControlsFixture {
    uint64 internal constant DELAY = 30 days;
    /// @notice The bit's slot: `IBCAdminStorage.SLOT + 42`, offset 0 (test_bitSlot).
    uint256 internal constant BIT_SLOT = uint256(S.SLOT) + 42;
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

    // ------------------------------------------------------------------------------------------------ layout --

    /// @notice The bit is the layout's last field, appended: slot SLOT + 42, nothing else written with it.
    function test_bitSlot() public {
        LayoutProbe probe = new LayoutProbe();
        probe.setBit();
        for (uint256 i = 0; i < 64; i++) {
            bytes32 v = vm.load(address(probe), bytes32(uint256(S.SLOT) + i));
            assertEq(v, i == 42 ? bytes32(uint256(1)) : bytes32(0));
        }
        assertEq(vm.load(address(admin), bytes32(BIT_SLOT)), bytes32(0), "enabled at launch");
        _disable();
        assertEq(vm.load(address(admin), bytes32(BIT_SLOT)), bytes32(uint256(1)));
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

    /// @notice An executor that clears the bit at recording: the frame is undone and the decision stays buffered
    /// (HALT); the recovery stays off, and a kind 9 (IBCAdmin's own) still replaces the executor.
    function test_maliciousExecutor_atRecording_halted() public {
        _disable();
        ReenablingExec bad = new ReenablingExec(address(router), d.accessManager, address(ics20), 1);
        _handover(address(bad));
        uint64 seq = admin.lastSeq() + 1;
        assertEq(_status(_recvGov(_env(seq, S.KIND_SETTINGS, P.settings(clientId, 2 days)))), S.STATUS_BUFFERED);
        assertEq(admin.lastSeq(), seq - 1, "nothing recorded");
        assertTrue(admin.recoveryDisabled());
        assertEq(vm.load(address(admin), bytes32(BIT_SLOT)), bytes32(uint256(1)));
        // as for any executor that cannot answer: gno.land cancels the stuck decision, and a kind 9 behind it
        // (IBCAdmin's own, never the executor's) puts an honest executor back
        IBCAdminExec good = new IBCAdminExec(address(router), d.accessManager, address(ics20));
        assertEq(
            _status(_recvGov(_env(seq + 1, S.KIND_HANDOVER, P.handover(address(good), address(good).codehash, "")))),
            S.STATUS_BUFFERED
        );
        _recvGov(_env(seq + 2, S.KIND_CANCEL, P.cancel1(seq, seq)));
        assertEq(admin.decision(1, seq + 1).state, S.PENDING, "the kind 9 recorded");
        _skip(S.WEEK);
        admin.execute(seq + 1);
        (address x,) = admin.exec();
        assertEq(x, address(good));
        assertTrue(admin.recoveryDisabled());
    }

    /// @notice An executor that clears the bit at execution: `keepRecoveryOff` reverts its frame, the decision is
    /// spent ("reverted"), and the recovery stays off.
    function test_maliciousExecutor_atExecution_reverted() public {
        _disable();
        ReenablingExec bad = new ReenablingExec(address(router), d.accessManager, address(ics20), 2);
        _handover(address(bad));
        uint64 seq = admin.lastSeq() + 1;
        assertEq(_status(_recvGov(_env(seq, S.KIND_UNPAUSE, P.unpause(2, "")))), S.STATUS_RECORDED);
        _skip(S.DAY);
        vm.expectEmit(true, true, false, true, address(admin));
        emit IIBCAdmin.DecisionSpent(1, seq, S.KIND_UNPAUSE, "reverted");
        admin.execute(seq);
        assertTrue(admin.recoveryDisabled());
        assertEq(vm.load(address(admin), bytes32(BIT_SLOT)), bytes32(uint256(1)));
    }

    /// @notice An executor that opens a proposal behind a disabled recovery: refused the same way.
    function test_maliciousExecutor_opensAProposal_reverted() public {
        _disable();
        ReenablingExec bad = new ReenablingExec(address(router), d.accessManager, address(ics20), 3);
        _handover(address(bad));
        uint64 seq = admin.lastSeq() + 1;
        assertEq(_status(_recvGov(_env(seq, S.KIND_UNPAUSE, P.unpause(2, "")))), S.STATUS_RECORDED);
        _skip(S.DAY);
        admin.execute(seq);
        assertEq(admin.decision(1, seq).state, S.SPENT);
        assertEq(_openedAt(), 0);
    }

    /// @notice An executor whose recovery module would switch the recovery on: IBCAdmin refuses before the module is
    /// reached, so neither an approval nor an execution runs it.
    function test_maliciousRecoveryModule_neverReached() public {
        _disable();
        ReenablingExec bad = new ReenablingExec(address(router), d.accessManager, address(ics20), 0);
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

    /// @notice The same executor with the recovery still on is not refused: the after-check guards only a disabled
    /// recovery (its frames there are an ordinary executor's).
    function test_executorFrames_unaffectedWhileEnabled() public {
        ReenablingExec bad = new ReenablingExec(address(router), d.accessManager, address(ics20), 2);
        _handover(address(bad));
        uint64 seq = admin.lastSeq() + 1;
        assertEq(_status(_recvGov(_env(seq, S.KIND_UNPAUSE, P.unpause(2, "")))), S.STATUS_RECORDED);
        _skip(S.DAY);
        admin.execute(seq);
        assertEq(admin.decision(1, seq).state, S.EXECUTED);
        assertFalse(admin.recoveryDisabled());
    }
}

/// @notice A deployment that never enabled the recovery starts with the bit set: kind 14 is spent ("disabled"), and
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
