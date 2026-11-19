// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ISignatureTransfer } from "@uniswap/permit2/src/interfaces/ISignatureTransfer.sol";
import { IICS02ClientMsgs } from "@eureka/msgs/IICS02ClientMsgs.sol";
import { IICS26RouterMsgs } from "@eureka/msgs/IICS26RouterMsgs.sol";
import { IICS20TransferMsgs } from "@eureka/msgs/IICS20TransferMsgs.sol";
import { ICS20Lib } from "@eureka/utils/ICS20Lib.sol";

import { IGnoICS20ControlsTypes as T } from "../../src/interfaces/IGnoICS20Controls.sol";
import { IIBCAdmin } from "../../src/interfaces/IIBCAdmin.sol";
import { IBCAdminStorage as S } from "../../src/admin/IBCAdminStorage.sol";
import { GovParams as P } from "../utils/GovParams.sol";
import { HookToken, ReentrantPermit2, ReentrantVerifier } from "../utils/ControlsMocks.sol";
import { IICS26RouterErrors } from "@eureka/errors/IICS26RouterErrors.sol";
import { Strings } from "@openzeppelin-contracts/utils/Strings.sol";
import { ControlsFixture } from "./ControlsFixture.sol";

/// @notice Round 11: external callees the transfer app calls mid-operation, tried as attackers. Each tries the
/// privileged entry points (the transfer app's claim and reopening continuation, IBCAdmin's drain, execute and
/// emergency execution) from inside the call, with work waiting for each; every one is refused: the transfer app's
/// shared lock (`ReentrancyGuardReentrantCall`), IBCAdmin's `Busy` (execute), a drain that records nothing while the
/// transfer app is busy. An emergency execution reaches the route only through the transfer app's locked entry points
/// (`setRecoveryBlock`, `migrateRoute`), so it reverts whole.
/// Tokens and sender adapters are covered in ReviewRegressions (ReentrantToken, HookToken) and the invariant
/// campaign (`busyGovernance`, `senderReentry`); kind 6 clients and other candidates are probed only by STATICCALL
/// (CandidateStatic.t.sol).
contract CalleeReentryTest is ControlsFixture {
    bytes4 internal constant LOCKED = bytes4(keccak256("ReentrancyGuardReentrantCall()"));
    ReentrantPermit2 internal p2;

    function _permit2() internal override returns (address) {
        p2 = new ReentrantPermit2();
        return address(p2);
    }

    function _prefix() internal pure returns (bytes[] memory p) {
        p = new bytes[](2);
        p[0] = "main";
        p[1] = "/pv/vm:gno.land/r/aib/ibc/core:";
    }

    /// @notice Work for IBCAdmin that a re-entering callee would like to run: a matured pending decision (seq 1) and
    /// decisions buffered beyond one drain.
    function _prime() internal returns (uint64 last) {
        _recvGov(_env(1, S.KIND_SETTINGS, P.settings(clientId, 1)));
        for (uint64 s = 3; s <= 3 + S.DRAIN + 2; s++) {
            _recvGov(_env(s, S.KIND_SETTINGS, P.settings(clientId, s)));
        }
        _recvGov(_env(2, S.KIND_SETTINGS, P.settings(clientId, 2))); // records 2.. up to the drain bound
        _skip(7 days + 1);
        last = admin.lastSeq();
        assertLt(last, 3 + S.DRAIN + 2, "work left to drain");
    }

    function _allRefused(address r, uint256 attempts, uint256 succeeded, uint64 last) internal view {
        assertEq(attempts, 1, "it tried");
        assertEq(succeeded, 0, "every privileged entry point refused");
        bytes4[4] memory want = [LOCKED, LOCKED, bytes4(0), IIBCAdmin.Busy.selector];
        for (uint256 i = 0; i < 4; i++) {
            bytes memory reason = r == address(p2) ? p2.reason(i) : ReentrantVerifier(r).reason(i);
            if (i == 2) assertEq(abi.decode(reason, (uint256)), 0, "drain recorded nothing");
            else assertEq(bytes4(reason), want[i], "the lock or Busy");
        }
        assertEq(admin.lastSeq(), last, "nothing recorded");
        assertEq(admin.decision(admin.epoch(), 1).state, S.PENDING, "nothing executed");
    }

    /// @notice The route's active verifier, asked by `proveOutcome`, re-enters: refused, and the proof stands.
    function test_r11_callee_verifierInProveOutcome() public {
        _setLimits(address(usdc), 1000, 1000, 1000);
        IICS26RouterMsgs.Packet memory pkt = _send(alice, address(usdc), 100, clientId);
        uint64 last = _prime();
        ReentrantVerifier v = new ReentrantVerifier();
        v.arm(address(ics20), address(admin), clientId);
        vm.startPrank(address(admin));
        router.addClient("gnoland-9", IICS02ClientMsgs.CounterpartyInfo("ethereum-9", _prefix()), address(v));
        ctl.migrateRoute(clientId, "gnoland-9", type(uint64).max);
        vm.stopPrank();
        T.OutcomeProof memory proof;
        proof.proofHeight = IICS02ClientMsgs.Height(0, 1);
        proof.receipt = ctl.gnoReceipt(pkt);
        proof.ack = bytes("{\"result\":\"AQ==\"}");
        assertEq(uint8(ctl.proveOutcome(pkt, proof)), uint8(T.Proven.Delivered));
        _allRefused(address(v), v.attempts(), v.succeeded(), last);
    }

    /// @notice Permit2, moving a send's tokens, re-enters: refused, and the send completes.
    function test_r11_callee_permit2InSend() public {
        _setLimits(address(usdc), 1000, 1000, 1000);
        uint64 last = _prime();
        p2.arm(address(ics20), address(admin), clientId);
        vm.prank(alice);
        usdc.approve(address(p2), type(uint256).max);
        ISignatureTransfer.PermitTransferFrom memory permit =
            ISignatureTransfer.PermitTransferFrom(ISignatureTransfer.TokenPermissions(address(usdc), 50), 0, 0);
        IICS20TransferMsgs.SendTransferMsg memory m = IICS20TransferMsgs.SendTransferMsg({
            denom: address(usdc),
            amount: 50,
            receiver: GNO_SENDER,
            sourceClient: clientId,
            destPort: ICS20Lib.DEFAULT_PORT_ID,
            timeoutTimestamp: uint64(_now() + 600),
            memo: ""
        });
        vm.prank(alice);
        uint64 seq = ics20.sendTransferWithPermit2(m, permit, "");
        assertEq(ctl.sendRecord(clientId, seq).amount, 50);
        _allRefused(address(p2), p2.attempts(), p2.succeeded(), last);
    }

    /// @notice r11: a token hook inside a send relays a pending inbound transfer (relaying is public): the transfer
    /// app is busy, and the delivery must not be consumed by an error ack. It reverts whole (an empty revert, which
    /// the router reports as `IBCFailedCallback`), nothing is written, and the packet is received normally after.
    function test_r11_callee_tokenHookRelaysAnInboundTransfer_notConsumed() public {
        _setLimits(address(usdc), 1000, 1000, 1000);
        _ack(_send(alice, address(usdc), 100, clientId), bytes("{\"result\":\"AQ==\"}")); // escrow to release
        HookToken hook = new HookToken();
        _setLimits(address(hook), 1000, 1000, 1000);
        hook.mint(alice, 10);
        vm.prank(alice);
        hook.approve(address(ics20), type(uint256).max);
        IICS20TransferMsgs.FungibleTokenPacketData memory data = IICS20TransferMsgs.FungibleTokenPacketData({
            denom: string.concat("transfer/", CP, "/", Strings.toHexString(address(usdc))),
            sender: GNO_SENDER,
            receiver: Strings.toHexString(bob),
            amount: 40,
            memo: ""
        });
        IICS26RouterMsgs.Packet memory pkt = _packetFromGno(
            clientId, ICS20Lib.DEFAULT_PORT_ID, ICS20Lib.ICS20_VERSION, ICS20Lib.ICS20_ENCODING, abi.encode(data)
        );
        hook.setHook(
            ics20.getEscrow(clientId),
            address(router),
            abi.encodeCall(router.recvPacket, (IICS26RouterMsgs.MsgRecvPacket(pkt, "", IICS02ClientMsgs.Height(0, 1))))
        );
        _send(alice, address(hook), 10, clientId); // the hook relays from inside the send
        assertFalse(hook.hookOk(), "the delivery from inside the send reverted");
        assertEq(bytes4(hook.hookRet()), IICS26RouterErrors.IBCFailedCallback.selector);
        assertEq(usdc.balanceOf(bob), 0);
        assertTrue(_isSuccessAck(_recv(pkt)), "received normally afterwards");
        assertEq(usdc.balanceOf(bob), 40);
    }

    /// @notice r11: the same for a governance delivery: from inside a send it reverts whole (IBCAdmin's busy refusal
    /// carries no data), so it is neither recorded nor acknowledged, and an honest relay records it after.
    function test_r11_callee_tokenHookRelaysAGovDelivery_notConsumed() public {
        HookToken hook = new HookToken();
        _setLimits(address(hook), 1000, 1000, 1000);
        hook.mint(alice, 20);
        vm.prank(alice);
        hook.approve(address(ics20), type(uint256).max);
        _send(alice, address(hook), 10, clientId); // the escrow exists
        uint64 seq = admin.lastSeq() + 1;
        IICS26RouterMsgs.Packet memory gov = _govPacket(_env(seq, S.KIND_SETTINGS, P.settings(clientId, 1)));
        hook.setHook(
            ics20.getEscrow(clientId),
            address(router),
            abi.encodeCall(router.recvPacket, (IICS26RouterMsgs.MsgRecvPacket(gov, "", IICS02ClientMsgs.Height(0, 1))))
        );
        _send(alice, address(hook), 10, clientId);
        assertFalse(hook.hookOk(), "reverted whole");
        assertEq(bytes4(hook.hookRet()), IICS26RouterErrors.IBCFailedCallback.selector);
        assertEq(admin.lastSeq(), seq - 1, "not recorded");
        bytes memory ack = _recv(gov);
        (,, uint8 status,) = _govAck(ack);
        assertEq(status, S.STATUS_RECORDED, "recorded by the honest relay");
    }
}
