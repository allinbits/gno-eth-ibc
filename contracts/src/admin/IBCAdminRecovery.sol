// SPDX-License-Identifier: LicenseRef-GNO-Network-GPL
pragma solidity ^0.8.28;

import { IICS02Client, IICS02ClientAccessControlled } from "@eureka/interfaces/IICS02Client.sol";
import { IICS02ClientMsgs } from "@eureka/msgs/IICS02ClientMsgs.sol";
import { IBCIdentifiers } from "@eureka/utils/IBCIdentifiers.sol";

import { IIBCAdmin } from "../interfaces/IIBCAdmin.sol";
import { IGnoICS20Controls } from "../interfaces/IGnoICS20Controls.sol";
import { IGnoLightClientStatus } from "../interfaces/IGnoLightClientStatus.sol";
import { IGnoLightClientMsgs } from "../msgs/IGnoLightClientMsgs.sol";
import { Guardians } from "../lib/Guardians.sol";
import { IBCAdminStorage as S } from "./IBCAdminStorage.sol";
import { IBCAdminChecks } from "./IBCAdminChecks.sol";

/// @title The emergency route replacement of ADR §7.12 (optional, off unless IBCAdmin enables it)
/// @notice Deployed by IBCAdminExec (so pinned with it) and delegatecalled by IBCAdmin, as IBCAdmin: a guardian
/// supermajority's proposal of an attested client opens only while the route is eligible, then blocks the route's
/// receives and suspends the authority-changing kinds; only guardians cancel it; after the long delay anyone executes
/// it as a route replacement (the new route stays closed until kinds 12 and 13).
contract IBCAdminRecovery is IIBCAdmin {
    address public immutable router;
    address public immutable ics20;
    address public immutable frozenClient;
    /// @notice The executor's stateless checks (a usable client, fail closed).
    address public immutable checks;
    address private immutable _self;

    constructor(address router_, address ics20_, address frozenClient_, address checks_) {
        (router, ics20, frozenClient, checks) = (router_, ics20_, frozenClient_, checks_);
        _self = address(this);
    }

    modifier delegated() {
        if (address(this) == _self) revert NotDelegated();
        _;
    }

    // ============================================================================================= recovery ==

    function _guardianSeat(address guardian) private view returns (uint256 seat) {
        seat = Guardians.position(S.layout().g.k, guardian);
        if (seat >= Guardians.SEATS) revert NotGuardian();
    }

    /// @notice A guardian approves a proposal (one per seat); it opens once `threshold` seats approve it while the
    /// route is eligible (§7.12 step 2), and while it is open every token receive on the route is refused and the
    /// authority-changing kinds are suspended.
    function approveRecovery(address guardian, bytes calldata proposal, RecoveryConfig calldata c) external delegated {
        uint256 seat = _guardianSeat(guardian);
        S.Layout storage l = S.layout();
        S.Recovery storage r = l.recovery;
        if (r.openedAt != 0) revert RecoveryState();
        RecoveryProposal memory rp = abi.decode(proposal, (RecoveryProposal));
        // every permanent condition execution needs is checked before the proposal can open: a proposal execution
        // must refuse for good would stay open and blocking until a cancellation quorum closes it
        if (!_freshId(rp.newClientId) || !_usableClient(l, rp)) revert RecoveryState();
        bytes32 h = keccak256(proposal);
        r.approved[seat] = h;
        if (bytes(r.params[h]).length == 0) r.params[h] = proposal;
        uint256 n;
        for (uint256 i = 0; i < Guardians.SEATS; i++) {
            if (r.approved[i] == h) n++;
        }
        emit RecoveryApproved(h, guardian, n);
        if (n < c.threshold || !_eligible(l, c)) return;
        r.proposal = h;
        r.openedAt = uint64(block.timestamp);
        r.cancels = 0;
        IGnoICS20Controls(ics20).setRecoveryBlock(l.govClient, true);
        emit RecoveryOpened(h, uint64(block.timestamp) + c.delay);
    }

    /// @notice Whether `id` can become the route's new client id at execution: a custom id in the router's grammar (4
    /// to 128 characters, never `client-` or `channel-`) and unknown to the router. Every id the transfer app knows
    /// (a route key, an alias, a retired id, an escrow's) was a router client, so this makes it a fresh route too;
    /// with the authority-changing kinds suspended while the proposal is open, it stays so until execution.
    function _freshId(string memory id) private view returns (bool) {
        if (!IBCIdentifiers.validateCustomIBCIdentifier(bytes(id))) return false;
        (bool exists,) = router.staticcall(abi.encodeCall(IICS02Client.getClient, (id)));
        return !exists;
    }

    /// @notice Whether a proposal's client is the pinned code, follows gno.land's chain id, and is neither frozen nor
    /// expired. Its height is not compared with the old client's: a poisoned client's height means nothing.
    function _usableClient(S.Layout storage l, RecoveryProposal memory rp) private view returns (bool) {
        address lc = rp.lightClient;
        if (!_isCode(lc) || lc.codehash != rp.codeHash) return false;
        if (!S.canonicalCounterparty(rp.counterpartyClientId, rp.merklePrefix)) return false;
        // its chain id and every status view answering exactly, not frozen, not expired (fail closed)
        return IBCAdminChecks(checks).usableClient(lc, l.gnoChainId);
    }

    /// @notice Eligible while the epoch's client is frozen or expired, the channel has been silent for `silence`,
    /// or a hold has stood on IBCAdmin for `holdPeriod`.
    function _eligible(S.Layout storage l, RecoveryConfig calldata c) private view returns (bool) {
        address lc = address(IICS02Client(router).getClient(l.govClient));
        // frozen or expired by an exact answer (a client that answers neither opens no recovery by its status; the
        // silence and the hold criteria still apply)
        if (_ask(lc, IGnoLightClientStatus.isFrozen.selector) || _ask(lc, IGnoLightClientStatus.isExpired.selector)) {
            return true;
        }
        // forge-lint: disable-next-line(block-timestamp)
        if (c.silence != 0 && block.timestamp - l.lastRecordTime >= c.silence) return true;
        (bool stands,, uint64 start) = S.hold(l);
        // forge-lint: disable-next-line(block-timestamp)
        return c.holdPeriod != 0 && stands && block.timestamp - start >= c.holdPeriod;
    }

    function _ask(address lc, bytes4 selector) private view returns (bool) {
        (bool answered, bool value) = IBCAdminChecks(checks).flag(lc, selector);
        return answered && value;
    }

    function _closeRecovery(S.Recovery storage r) private {
        r.proposal = bytes32(0);
        r.openedAt = 0;
        r.cancels = 0;
        delete r.approved;
    }

    /// @notice Executes the open proposal once its delay has passed (§7.12 step 4): adds the attested client under
    /// its new id, migrates the route, freezes the old id and opens the next epoch over the new one.
    function executeRecovery(RecoveryConfig calldata c) external delegated {
        S.Layout storage l = S.layout();
        S.Recovery storage r = l.recovery;
        if (r.openedAt == 0) revert RecoveryState();
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < uint256(r.openedAt) + c.delay) revert NotMature(r.openedAt + c.delay);
        bytes32 h = r.proposal;
        RecoveryProposal memory rp = abi.decode(r.params[h], (RecoveryProposal));
        // the attested client must still be usable now: its pinned code, this chain, neither frozen nor expired
        if (!_usableClient(l, rp)) revert RecoveryState();
        string memory oldId = l.govClient;
        IICS02ClientMsgs.CounterpartyInfo memory info =
            IICS02ClientMsgs.CounterpartyInfo(rp.counterpartyClientId, rp.merklePrefix);
        IICS02ClientAccessControlled(router).addClient(rp.newClientId, info, rp.lightClient);
        IGnoICS20Controls(ics20).checkpointForReplacement(oldId);
        IGnoICS20Controls(ics20).migrateRoute(oldId, rp.newClientId, rp.suspectFrom);
        // the route (now the new id's) was blocked while the proposal was open
        IGnoICS20Controls(ics20).setRecoveryBlock(rp.newClientId, false);
        S.replaceRoute(l, router, frozenClient, oldId, rp.newClientId);
        _closeRecovery(r);
        emit RecoveryExecuted(h, rp.newClientId);
    }

    /// @notice Whether `a` holds contract code, and not an EIP-7702 delegation designator.
    function _isCode(address a) private view returns (bool) {
        uint256 size;
        bytes32 head;
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            size := extcodesize(a)
            let ptr := mload(0x40)
            mstore(ptr, 0)
            extcodecopy(a, ptr, 0, 3)
            head := mload(ptr)
        }
        return size != 0 && bytes3(head) != 0xef0100;
    }
}
