// SPDX-License-Identifier: LicenseRef-GNO-Network-GPL
pragma solidity ^0.8.28;

import { IIBCAdmin } from "../interfaces/IIBCAdmin.sol";
import { IGnoICS20Controls } from "../interfaces/IGnoICS20Controls.sol";
import { Guardians } from "../lib/Guardians.sol";
import { IBCAdminStorage as S } from "./IBCAdminStorage.sol";
import { IBCAdminExec } from "./IBCAdminExec.sol";

/// @title IBCAdmin's own paths that never depend on the executor
/// @notice Part of IBCAdmin's immutable code: IBCAdmin deploys it in its constructor and delegatecalls it at that
/// address, which nothing can change (no pointer to it is stored, and since Cancun SELFDESTRUCT no longer removes
/// code), so it runs exactly the code IBCAdmin was built with, never the installed executor's. It holds what must
/// work whatever the executor does: kind 9 (the hand-over that replaces a broken executor), the guardians'
/// cancellation of an open emergency recovery (which suspends kind 9 while it stands), and kind 14 (the permanent
/// disable of that recovery, which no executor may undo). Called at its own address,
/// every function refuses (`NotDelegated`): it acts only as IBCAdmin.
contract IBCAdminNative is IIBCAdmin {
    /// @notice The gas the transfer app's `setRecoveryBlock` gets when a cancellation lifts the recovery block.
    uint256 internal constant UNBLOCK_GAS = 200_000;

    address private immutable _self = address(this);

    /// @notice The executor's answer at recording failed validation: reverted so that whatever the executor did in the
    /// frame is undone; IBCAdmin reads it as HALT (the decision stays buffered, nothing recorded or applied).
    error Halted();

    modifier delegated() {
        if (address(this) == _self) revert NotDelegated();
        _;
    }

    /// @notice The executor's verdict on a decision at recording, run with a fixed gas budget (RECORD_GAS): its
    /// WAIT, DONE_NOW or SPEND (a revert, as undecodable parameters, spends the decision). IBCAdmin's own answers:
    /// HALT when the executor cannot answer, its code not the pinned one or its answer not exactly the canonical
    /// `abi.encode(uint8 action, string reason)` with a known action (length, offset, bounds and zero padding all
    /// checked), and STARVED with less gas left than the budget needs. Neither records anything: the decision stays
    /// buffered (and a starved delivery reverts whole), so no relayer can spend or consume a decision by starving it.
    function atRecording(
        uint8 kind,
        uint64 seq,
        bytes calldata params,
        bool suspended
    )
        external
        delegated
        returns (uint8, string memory)
    {
        // kinds 9 and 14 are IBCAdmin's own: their parameters checked here, never by the executor
        if (kind == S.KIND_HANDOVER) return S.handoverParams(params);
        S.Layout storage l = S.layout();
        if (kind == S.KIND_DISABLE_RECOVERY) {
            string memory why = S.disableRecoveryCheck(l, params);
            return bytes(why).length == 0 ? (S.WAIT, "") : (S.SPEND, why);
        }
        bool wasOff = l.recoveryDisabled;
        address x = l.exec;
        if (x.codehash != l.execHash) return (S.HALT, "");
        if (gasleft() < S.RECORD_FLOOR) return (S.STARVED, "");
        bytes memory data = abi.encodeCall(IBCAdminExec.atRecording, (kind, seq, params, suspended));
        uint256 budget = S.RECORD_GAS;
        bool ok;
        uint256 size;
        // the answer's size is read before anything is copied: a hostile answer cannot spend the floor's margin
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            ok := delegatecall(budget, x, add(data, 32), mload(data), 0, 0)
            size := returndatasize()
        }
        // a revert undid the executor's own effects; as undecodable parameters, it spends the decision
        if (!ok) return (S.SPEND, "params");
        // an executor that wrote a disabled recovery back on (or opened a proposal): the frame undone, HALT
        if (wasOff && (!l.recoveryDisabled || l.recovery.openedAt != 0)) revert Halted();
        // from here a refusal reverts (Halted), undoing whatever the executor did in this frame
        if (size < 96 || size > S.MAX_ANSWER) revert Halted();
        bytes memory ret = new bytes(size);
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            returndatacopy(add(ret, 32), 0, size)
        }
        (uint256 a, uint256 off, uint256 n) = abi.decode(ret, (uint256, uint256, uint256));
        // decodable (a known action, the string's offset and bounds), then equal to its canonical re-encoding: no
        // trailing data, the padding present and zero
        if (a > S.SPEND || off != 0x40 || n > size - 96) revert Halted();
        (uint8 action, string memory reason) = abi.decode(ret, (uint8, string));
        if (keccak256(abi.encode(action, reason)) != keccak256(ret)) revert Halted();
        return (action, reason);
    }

    /// @notice When a pending seat change (kind 3, `flags` false) or hand-over (kind 9, `flags` true) may land
    /// (`due`), and whether this call pinned an anchor (it then must not revert: the caller returns, pending, before
    /// `due`). From `matureAt` (its 7 days), the deferrals applied, each only while its cause stands:
    /// - **under a hold** (both kinds; ADR §7.4): no sooner than the hold anchor plus 21 days, the anchor the start of
    ///   the first hold standing at or after `matureAt` (`IBCAdminStorage.anchor`: the hold history, `end` exclusive,
    ///   merged intervals never an anchor), pinned in `seatAnchor` the first time it is seen due and held;
    /// - **under flags** (kind 9 only; any standing flag, or a conflict's): no sooner than the flag anchor plus 21
    ///   days, the anchor the earliest start (`flagTime`) of the flags standing the first time it is seen due and
    ///   flagged (a conflict's flag counting from that moment), pinned in `flagAnchor` and never reset: a flag set,
    ///   cleared or set again later does not move it. A flag standing since before `matureAt` counts from its own
    ///   start. A seat change is never deferred by flags (it is how a flagging key is replaced).
    /// With no hold (and, for kind 9, no flag) it lands at `matureAt`.
    function due(
        uint32 ep,
        uint64 seq,
        uint64 matureAt,
        bool flags
    )
        external
        delegated
        returns (uint64 landsAt, bool pinned)
    {
        S.Layout storage l = S.layout();
        landsAt = matureAt;
        uint64 now_ = uint64(block.timestamp);
        (bool holdStands,, uint64 holdStart) = S.hold(l);
        if (holdStands) {
            uint64 a = l.seatAnchor[ep][seq];
            if (a == 0 && now_ >= matureAt) {
                a = S.anchor(l, matureAt, holdStart);
                l.seatAnchor[ep][seq] = a;
                emit ReplacementAnchored(ep, seq, a + S.HOLD_REPLACEMENT);
                pinned = true;
            }
            if (a + S.HOLD_REPLACEMENT > landsAt) landsAt = a + S.HOLD_REPLACEMENT;
        }
        if (flags && S.flagged(l)) {
            uint64 f = l.flagAnchor[ep][seq];
            if (f == 0 && now_ >= matureAt) {
                f = l.conflictBlock != 0 ? now_ : type(uint64).max;
                for (uint256 i = 0; i < Guardians.KEYS; i++) {
                    if (Guardians.standing(l.g.k, l.g.f, i) && l.g.f.flagTime[i] < f) f = l.g.f.flagTime[i];
                }
                l.flagAnchor[ep][seq] = f;
                emit ReplacementAnchored(ep, seq, f + S.HOLD_REPLACEMENT);
                pinned = true;
            }
            if (f + S.HOLD_REPLACEMENT > landsAt) landsAt = f + S.HOLD_REPLACEMENT;
        }
    }

    /// @notice Kind 9 `(exec, codeHash, migrationCall)`, its migration call empty (IBCAdminStorage.handoverParams):
    /// `exec`'s code is the decision's (contract code, not an EIP-7702 designator) and its `bindings()` answer, in
    /// BIND_GAS, exactly IBCAdmin's router, AccessManager and transfer app; then the pin moves. No state or authority
    /// moves: both stay in IBCAdmin. A failed check spends the decision ("codehash", "bindings").
    function handover(
        bytes calldata p,
        address router,
        address accessManager,
        address ics20
    )
        external
        delegated
        returns (string memory)
    {
        (address x, bytes32 h) = abi.decode(p, (address, bytes32));
        if (!S.isCode(x) || x.codehash != h) return "codehash";
        bytes4 sel = bytes4(keccak256("bindings()"));
        uint256 bindGas = S.BIND_GAS;
        bool ok;
        uint256 n;
        uint256 r;
        uint256 am;
        uint256 t;
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, sel)
            ok := staticcall(bindGas, x, ptr, 4, ptr, 96)
            n := returndatasize()
            r := mload(ptr)
            am := mload(add(ptr, 32))
            t := mload(add(ptr, 64))
        }
        if (!ok || n != 96 || r != uint160(router) || am != uint160(accessManager) || t != uint160(ics20)) {
            return "bindings";
        }
        S.Layout storage l = S.layout();
        l.exec = x;
        l.execHash = h;
        emit ExecReplaced(x, h);
        return "";
    }

    /// @notice Kind 14 at execution: its checks again (`IBCAdminStorage.disableRecoveryCheck`, a failure spends it),
    /// then the emergency recovery is off for good: the bit set and every pending approval cleared. IBCAdmin never
    /// executes it while a proposal is open (kind 14 is suspended then); were one open, it reverts and pends. Nothing
    /// clears the bit: no kind writes it, IBCAdmin reads it before any recovery call reaches the executor's module,
    /// and it refuses every executor frame that leaves it cleared (`keepRecoveryOff`, and HALT at recording).
    function disableRecovery(uint32 ep, uint64 seq, bytes calldata p) external delegated returns (string memory) {
        S.Layout storage l = S.layout();
        string memory why = S.disableRecoveryCheck(l, p);
        if (bytes(why).length != 0) return why;
        S.Recovery storage r = l.recovery;
        if (r.openedAt != 0) revert Suspended();
        l.recoveryDisabled = true;
        S.closeRecovery(r);
        emit EmergencyRecoveryDisabled(ep, seq);
        return "";
    }

    /// @notice Before a proposal opens, a guardian withdraws its approval; once open, it votes to cancel, and
    /// `cancelThreshold` votes close it: the proposal and every approval cleared, the suspended kinds free to run
    /// again, and the route's recovery block lifted, best effort: if the transfer app refuses (or exhausts
    /// UNBLOCK_GAS), the recovery still closes and the route stays blocked (`RecoveryBlockKept`), the safe
    /// direction, until `clearRecoveryBlock` succeeds (after a kind 7 repairs the transfer app).
    function cancelRecovery(address guardian, uint8 cancelThreshold, address ics20) external delegated {
        S.Layout storage l = S.layout();
        uint256 seat = Guardians.position(l.g.k, guardian);
        if (seat >= Guardians.SEATS) revert NotGuardian();
        S.Recovery storage r = l.recovery;
        if (r.openedAt == 0) {
            r.approved[seat] = bytes32(0);
            return;
        }
        uint8 votes = r.cancels | uint8(1 << seat);
        r.cancels = votes;
        // the votes counted: the nibble at `votes` of this table is the number of bits set in it (four seats)
        uint256 n = (0x4332322132212110 >> (uint256(votes) * 4)) & 0xf;
        bytes32 h = r.proposal;
        emit RecoveryCancelVote(h, guardian, n);
        if (n < cancelThreshold) return;
        emit RecoveryCancelled(h);
        S.closeRecovery(r);
        // a caller starving the call cannot leave the block standing on purpose: below the call's budget it reverts
        if (gasleft() < UNBLOCK_GAS * 64 / 63 + 20_000) revert CallStarved();
        try IGnoICS20Controls(ics20).setRecoveryBlock{ gas: UNBLOCK_GAS }(l.govClient, false) { }
        catch {
            emit RecoveryBlockKept(h);
        }
    }

    /// @notice Lifts a recovery block that a cancellation left standing (`RecoveryBlockKept`): with no recovery open,
    /// the route of the current client must not stay blocked. Permissionless; reverts while the transfer app still
    /// refuses, and does nothing when there is no block to lift.
    function clearRecoveryBlock(address ics20) external delegated {
        S.Layout storage l = S.layout();
        if (l.recovery.openedAt != 0) revert RecoveryState();
        if (IGnoICS20Controls(ics20).recoveryBlocked(l.govClient)) {
            IGnoICS20Controls(ics20).setRecoveryBlock(l.govClient, false);
        }
    }
}
