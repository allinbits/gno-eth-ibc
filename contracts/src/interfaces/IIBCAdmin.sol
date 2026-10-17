// SPDX-License-Identifier: LicenseRef-GNO-Network-GPL
pragma solidity ^0.8.28;

// The decision lifecycle, kinds and guardian rules follow gnolang/bridges (branch ethereum-draft),
// ethereum/bridge/contracts/src/interfaces/IHlAdmin.sol and HlAdmin.sol; the delivery protocol is ADR pr6375 §5.4.
// Copyright (C) 2026 NewTendermint, LLC. GNO Network General Public License: see contracts/licenses/.

import { IGuardians } from "./IGuardians.sol";

/// @title IBCAdmin: the permanent governance app on port `gov` (ADR pr6375 E8, §5.4, §7.6, §7.12)
interface IIBCAdmin {
    /// @notice A decision of the current epoch as stored.
    struct Decision {
        bytes32 hash;
        uint8 kind;
        uint8 state;
        bool bad;
        uint64 recordedTime;
        uint64 recordedBlock;
        bytes params;
    }

    /// @notice A guardian-proposed emergency route replacement (§7.12).
    struct RecoveryProposal {
        string newClientId;
        string counterpartyClientId;
        bytes[] merklePrefix;
        address lightClient;
        bytes32 codeHash;
        /// The Ethereum block from which the old client's acks and timeouts are suspect (§7.12).
        uint64 suspectFrom;
    }

    /// @notice The recovery's settings, fixed at deployment. `delay == 0` disables the emergency path.
    /// @notice What the deployment created, for `finishSetup` to check against the chain (ADR E11): the launch
    /// client's id, its verifier (address and code hash), the verifier's original checkpoint (its launch height and
    /// the hash of the consensus state stored there) and its parameters no update changes (the hash of
    /// `abi.encode(chainId, revisionNumber, trustLevel, trustingPeriod, maxClockDrift)`), gno.land's client id on
    /// the other side, the ugnot voucher and the route's quarantine. Verified updates since the launch height are
    /// allowed: anyone may relay one. Zero hashes are not checked (a verifier the deployment did not create).
    struct Launch {
        string clientId;
        address lightClient;
        bytes32 lightClientCodeHash;
        uint64 launchHeight;
        bytes32 clientParamsHash;
        bytes32 consensusStateHash;
        string counterpartyClientId;
        address ugnotVoucher;
        uint64 quarantineSeconds;
    }

    struct RecoveryConfig {
        uint64 delay;
        uint8 threshold;
        uint8 cancelThreshold;
        uint64 silence;
        uint64 holdPeriod;
    }

    // --------------------------------------------------------------------------- expected refusals (error acks) --

    error NotRouter(address caller);
    error BadPayload();
    error WrongClient(string clientId);
    error Undecodable();
    error StaleEpoch(uint32 epoch, uint32 current);
    error BeyondWindow(uint64 seq, uint64 last);
    error ExecutionStarved();
    error NotSupported();

    // ------------------------------------------------------------------------------------------ other refusals --

    error ZeroAddress();
    error ForeignExec();
    error NotPending(uint64 seq);
    error NotMature(uint64 matureAt);
    error Deferred();
    /// @notice A transfer-app entry point is running (a hook called in): the decision pends.
    error Busy();
    error Suspended();
    error NotDelegated();
    error NoCodeYet(address target);
    error CallStarved();
    error SetupAlreadyDone();
    error SetupIncomplete(uint8 check);
    /// @notice Governance waits for `finishSetup`: nothing is recorded, executed or recovered before it.
    error SetupPending();
    /// @notice No epoch notice is owed: none since the launch, or gno.land acknowledged it.
    error NoNoticeOwed();
    error RecoveryDisabled();
    error RecoveryNotEligible();
    error RecoveryState();
    error NotGuardian();
    error AuthorityLost(address target);
    error NotSelf();

    // ---------------------------------------------------------------------------------------------------- events --

    event DecisionReceived(
        uint32 indexed epoch, uint64 indexed seq, uint8 kind, bytes32 hash, uint8 status, bool redispatch
    );
    event DecisionRecorded(uint32 indexed epoch, uint64 indexed seq, uint8 kind, uint64 matureAt);
    event DecisionExecuted(uint32 indexed epoch, uint64 indexed seq, uint8 kind);
    event DecisionSpent(uint32 indexed epoch, uint64 indexed seq, uint8 kind, string reason);
    event DecisionCancelled(uint32 indexed epoch, uint64 indexed seq);
    event Tombstoned(uint32 indexed epoch, uint64 from, uint64 to);
    event Conflict(uint32 indexed epoch, uint64 indexed seq, bytes32 stored, bytes32 received);
    event FlagSet(address indexed key, uint8 seat);
    event FlagCleared(address indexed key, uint8 seat);
    event HoldEnded(uint64 start, uint64 end);
    event Unpaused(uint64 beforeBlock, uint256 cleared);
    event GuardiansSet(uint8 seat, address key);
    event EpochOpened(uint32 indexed epoch, string clientId);
    event ExecReplaced(address exec, bytes32 codeHash);
    event RecoveryApproved(bytes32 indexed proposal, address indexed guardian, uint256 approvals);
    event RecoveryOpened(bytes32 indexed proposal, uint64 executableAt);
    event RecoveryCancelVote(bytes32 indexed proposal, address indexed guardian, uint256 votes);
    event RecoveryCancelled(bytes32 indexed proposal);
    event RecoveryExecuted(bytes32 indexed proposal, string newClientId);
    event SetupDone();
    /// @notice The epoch notice sent over the new client (§7.12); `sequence` zero: the router refused it, resend.
    event EpochNoticeSent(uint32 indexed epoch, string clientId, uint64 sequence);
    /// @notice An acknowledgement (`done`: gno.land switched) or, `done` false, an error ack or a timeout: resend.
    event EpochNoticeAcknowledged(uint32 indexed epoch, uint64 sequence, bool done);
}
