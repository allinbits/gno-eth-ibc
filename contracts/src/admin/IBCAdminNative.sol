// SPDX-License-Identifier: LicenseRef-GNO-Network-GPL
pragma solidity ^0.8.28;

import { IIBCAdmin } from "../interfaces/IIBCAdmin.sol";
import { IGnoICS20Controls } from "../interfaces/IGnoICS20Controls.sol";
import { Guardians } from "../lib/Guardians.sol";
import { IBCAdminStorage as S } from "./IBCAdminStorage.sol";

/// @title IBCAdmin's own paths that never depend on the executor
/// @notice Part of IBCAdmin's immutable code: IBCAdmin deploys it in its constructor and delegatecalls it at that
/// address, which nothing can change (no pointer to it is stored, and since Cancun SELFDESTRUCT no longer removes
/// code), so it runs exactly the code IBCAdmin was built with, never the installed executor's. It holds what must
/// work whatever the executor does: kind 9 (the hand-over that replaces a broken executor) and the guardians'
/// cancellation of an open emergency recovery (which suspends kind 9 while it stands). Called at its own address,
/// every function refuses (`NotDelegated`): it acts only as IBCAdmin.
contract IBCAdminNative is IIBCAdmin {
    /// @notice The gas the transfer app's `setRecoveryBlock` gets when a cancellation lifts the recovery block.
    uint256 internal constant UNBLOCK_GAS = 200_000;

    address private immutable _self = address(this);

    modifier delegated() {
        if (address(this) == _self) revert NotDelegated();
        _;
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
        r.proposal = bytes32(0);
        r.openedAt = 0;
        r.cancels = 0;
        delete r.approved;
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
