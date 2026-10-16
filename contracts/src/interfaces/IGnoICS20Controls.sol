// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IICS26RouterMsgs } from "@eureka/msgs/IICS26RouterMsgs.sol";
import { IICS02ClientMsgs } from "@eureka/msgs/IICS02ClientMsgs.sol";
import { IGuardians } from "./IGuardians.sol";

/// @title The types, errors and events of the controls GnoICS20Transfer adds to eureka's ICS20Transfer (ADR pr6375
/// E5-E7, E9, E12, §7.2-§7.4, §7.10, §7.12, §7.13)
/// @notice Every control is keyed by a route: a stable route key (the first client id the route had) that each of
/// its client ids aliases. Receive limits, send limits, flags, the refunds hold, the quarantine duration, escrows and
/// the voucher registry follow the route when `migrateRoute` re-points a new client id at it.
interface IGnoICS20ControlsTypes {
    /// @notice A route's limits for one token. Receive: `maxPerMessage` and a leaky-bucket `dayCap`. Refunds: a
    /// leaky-bucket `refundCap`. Sends of escrowed (Ethereum-native) tokens: `sendMax`/`sendMin`, 0 = unset.
    struct Limits {
        uint256 maxPerMessage;
        uint256 dayCap;
        uint256 refundCap;
        uint256 sendMax;
        uint256 sendMin;
    }

    /// @notice Limits as read back, with the buckets' current levels.
    struct LimitsView {
        bool set;
        Limits limits;
        uint256 receiveLevel;
        uint256 refundLevel;
    }

    /// @notice What the ack or timeout callback attached to a send record.
    enum Outcome {
        Pending,
        Success,
        ErrorAck,
        Timeout
    }

    /// @notice A send record's destination outcome, proven through the route's replacement client (`proveOutcome`,
    /// ADR §7.12): delivered (its receipt and a success ack), refundable (an error ack, or no receipt once it can no
    /// longer be received), or a collision (another packet's receipt at its sequence: the honest one is refundable).
    enum Proven {
        None,
        Delivered,
        Refundable,
        Collision
    }

    /// @notice The destination's state for one packet at `proofHeight`: its receipt with a membership proof and its
    /// app acknowledgement with a membership proof of the ack commitment; or `receipt` zero and a non-membership
    /// proof of the receipt (`ack`, `ackProof` unused). A receipt other than the packet's needs no ack.
    struct OutcomeProof {
        IICS02ClientMsgs.Height proofHeight;
        bytes32 receipt;
        bytes receiptProof;
        bytes ack;
        bytes ackProof;
    }

    /// @notice The refund state of a send record: none owed, paid at once, queued under the refund meter or the
    /// refunds hold, paid in full by `claim`, or parked: its payment reverted (a token that refuses the sender, a
    /// paused token), so it waits apart and `claimParked` retries it, and no other refund waits behind it.
    enum Payment {
        None,
        Paid,
        Queued,
        Claimed,
        Parked,
        Rejected
    }

    /// @notice The per-packet send record (§7.13), keyed by (source client id, sequence). Written by every send
    /// variant after the router returned the sequence (or by `backfill` for a packet sent before the fork, while the
    /// router still holds its commitment); the ack and timeout callbacks only attach the outcome, the local
    /// processing block and the payment state, and refuse a packet without a record. `commitment` is the router's
    /// packet commitment, which binds the full packet (timeout and payload; the packet itself is in the router's
    /// SendPacket event and is authenticated against it).
    struct SendRecord {
        bytes32 commitment;
        address sender;
        address token;
        address escrow;
        uint64 timeoutTimestamp;
        uint64 sendBlock;
        uint64 processedBlock;
        /// The record's index in its route's list of processed records (meaningful once `processedBlock` is set).
        uint64 processedIndex;
        bool burned;
        Outcome outcome;
        Payment payment;
        uint256 amount;
        uint256 refunded;
        /// Backfilled for a packet sent before the fork was installed (authenticated against the router's
        /// commitment; `sendBlock` is the backfill's block).
        bool legacy;
        /// The reconciliation outcome kind 12 applied (0: none; 1 refund, 2 rejected, 3 delivered, 4 forged
        /// refund).
        uint8 settlement;
        /// Still open: an outstanding packet, or a refund owed (queued, parked) not settled by kind 12.
        bool open;
        /// The destination outcome `proveOutcome` verified, which kind 12's actions 1-4 must match, and the light
        /// client that verified it: void once that client is no longer the route's active one (frozen, expired, or
        /// replaced), when kind 12 refuses it and a new proof may replace it.
        Proven proven;
        address provenBy;
        /// The route's verifier generation when it was proven: any re-pointing of the route's client since voids it.
        uint64 provenGen;
    }

    /// @notice One reconciliation outcome of kind 12 (ADR §5.4, §7.12) for the send record at `sequence`.
    struct SettleItem {
        uint64 sequence;
        uint8 action;
        uint256 amount;
    }

    // ------------------------------------------------------------------------------------- expected refusals --
    // The router turns a receive callback's revert with non-empty data into an error acknowledgement, which
    // refunds the sender at the source.

    error GnoClientRetired(string clientId);
    error GnoRoutePaused(string clientId);
    error GnoRouteRecovering(string clientId);
    error GnoRouteClosed(string clientId);
    error GnoNoSendRecord(string clientId, uint64 sequence);
    error GnoBadBackfill();
    error GnoBadSettlement(uint256 item);
    error GnoNotClosed(string clientId);
    error GnoNoNotification(string clientId, uint64 sequence);
    error GnoBadProof();
    error GnoRouteReopening(string clientId);
    error GnoRecordsOpen(string clientId, uint64 open);
    error GnoSuspectUnsettled(string clientId, uint64 open);
    error GnoEscrowReserved(address token, uint256 balance, uint256 reserved);
    error GnoQuarantined(string clientId, uint256 until);
    error GnoQuarantineUnknown(string clientId);
    error GnoDenomNotRegistered(string denom);
    error GnoLimitsNotSet(string clientId, address token);
    error GnoOverMaxPerMessage(address token, uint256 amount, uint256 maxPerMessage);
    error GnoOverDayCap(address token, uint256 amount, uint256 dayCap);
    error GnoSendAboveMax(address token, uint256 amount, uint256 sendMax);
    error GnoSendBelowMin(address token, uint256 amount, uint256 sendMin);
    error GnoRefundsHeld(string clientId);
    error GnoBadLimits();
    error GnoBadRoute();
    error GnoNotParked(string clientId, uint64 sequence);
    error GnoRefundFailed(string clientId, uint64 sequence);

    // ------------------------------------------------------------------------------------------------ events --

    event GnoRouteFlagSet(string routeKey, address indexed key, uint8 seat, bool refunds);
    event GnoRouteFlagCleared(string routeKey, address indexed key, uint8 seat, bool refunds);
    event GnoRouteUnpaused(string routeKey, uint64 beforeBlock, uint256 cleared);
    event GnoGuardianKeysSet(address[6] keys);
    event GnoLimitsSet(string routeKey, address indexed token, Limits limits);
    event GnoQuarantineSet(string routeKey, uint64 quarantineSeconds);
    event GnoRecoveryBlockSet(string routeKey, bool blocked);
    event GnoRouteMigrated(string oldClientId, string newClientId, string routeKey);
    event GnoSendRecorded(string clientId, uint64 indexed sequence, bytes32 commitment, address token, uint256 amount);
    event GnoOutcomeRecorded(string clientId, uint64 indexed sequence, Outcome outcome, Payment payment);
    event GnoRefundPaid(string clientId, uint64 indexed sequence, address token, address to, uint256 amount);
    event GnoRefundQueued(string clientId, uint64 indexed sequence, address token, uint256 amount);
    event GnoRefundParked(string clientId, uint64 indexed sequence, address token, uint256 amount);
    event GnoRefundRejected(string clientId, uint64 indexed sequence);
    /// @notice An ack or timeout of a record reconciliation already settled: ignored.
    event GnoOutcomeIgnored(string clientId, uint64 indexed sequence, Outcome outcome);
    event GnoSettled(string clientId, uint64 indexed sequence, uint8 action, uint256 amount);
    event GnoLossRecorded(string routeKey, address indexed token, uint64 indexed sequence, uint256 amount);
    event GnoRouteReopened(string routeKey);
    /// @notice Kind 13 accepted a recorded loss not recapitalized as a deficit of the route (ADR §7.9).
    event GnoDeficitAccepted(string routeKey, address indexed token, uint256 amount);
    event GnoBackfilled(string clientId, uint64 indexed sequence, bytes32 commitment);
    /// @notice A reopening found a prerequisite broken at its last batch (a record opened meanwhile): the route
    /// stays closed, for kind 12 and a new kind 13.
    event GnoReopenAborted(string routeKey);
    event GnoOutcomeProven(string clientId, uint64 indexed sequence, Proven proven);
    /// @notice The sender's IIBCSenderCallbacks notification of an error ack or timeout, delivered once the refund
    /// is paid; `ok` false when the sender reverted (the refund stands).
    event GnoSenderNotified(string clientId, uint64 indexed sequence, bool ok);
    /// @notice A refund paid by reconciliation (kind 12): its sender's notification is due, delivered by
    /// `retryNotification` (a settlement never loads it).
    event GnoNotificationDue(string clientId, uint64 indexed sequence);
}

/// @title The functions of the controls (served by GnoICS20Controls through GnoICS20Transfer's fallback)
interface IGnoICS20Controls is IGnoICS20ControlsTypes {
    // ------------------------------------------------------------------------------------------- governance --
    // Restricted by the AccessManager to ADMIN_ROLE (IBCAdmin).

    /// @notice One-time setup of the fork's storage in the UUPS upgrade from eureka's ICS20Transfer.
    function initializeGno(address[6] calldata keys) external;
    function setGuardianKeys(address[6] calldata keys) external;
    function setLimits(string calldata clientId, address token, Limits calldata limits) external;
    function setQuarantine(string calldata clientId, uint64 quarantineSeconds) external;
    /// @notice Stores the route's quarantine deadline so far (its current client's transitions): IBCAdmin calls it
    /// before any verifier swap (kind 6 migrate, kind 10, the emergency recovery), so a swap never drops it.
    function checkpointQuarantine(string calldata clientId) external;
    /// @notice Clears the route's flags and refunds flags set at a block before `beforeBlock`; refused while either
    /// set holds (IGuardians.HoldStands).
    function unpauseRoute(string calldata clientId, uint64 beforeBlock) external returns (uint256 cleared);
    /// @notice Refuses (or allows again) every token receive on the route while an emergency recovery is open.
    function setRecoveryBlock(string calldata clientId, bool blocked) external;
    /// @notice Points `newClientId` at `oldClientId`'s route, retires `oldClientId` and closes the route (constant
    /// work); kind 12 settles its records and kind 13 reopens it.
    /// `suspectFrom`: the Ethereum block from which acks and timeouts processed through the old client are suspect;
    /// each record processed from then on must be settled by kind 12 before kind 13 (never reaching back past the
    /// previous replacement). Refused while the route is closed (one replacement at a time).
    function migrateRoute(string calldata oldClientId, string calldata newClientId, uint64 suspectFrom) external;
    /// @notice Kind 13: starts reopening a closed route, refused while any of its send records is open
    /// (`openRecords`). Every recorded loss not yet accepted becomes an accepted deficit, in batches: the first here,
    /// the rest by `continueReopen`; the route opens when the last batch completes.
    function reopenRoute(string calldata clientId) external;
    /// @notice Accepts the next batch (at most 16 tokens) of a reopening route's deficits, and opens it after the
    /// last. Permissionless.
    function continueReopen(string calldata clientId, uint256 n) external;
    /// @notice Kind 12: applies reconciliation outcomes to send records of a retired client id, each at most once:
    /// 1 genuine refund: pay its remainder (`amount` must equal the amount less what was refunded, zero when it was
    /// paid in full, which only settles the record; parked if the token refuses), 2 reject a queued or parked refund,
    /// 3 settled as delivered (a queued or parked refund is rejected), 2 and 3 only when nothing was refunded yet,
    /// 4 forged refund: reject the unpaid remainder and record what was already paid as a loss (`amount` must equal
    /// what was paid). All or nothing.
    function settleRecords(string calldata clientId, SettleItem[] calldata items) external;
    /// @notice Delivers a sender notification kept after it failed, once its outcome is final for the sender (a
    /// success ack, or a refund paid in full). Permissionless; it only calls the sender, never pays. Returns whether
    /// the sender took it (if not, it stays kept).
    function retryNotification(string calldata clientId, uint64 sequence) external returns (bool);

    /// @notice Permissionless: notifies the sender of a refund kind 12 paid (action 1, paid in full) for a packet
    /// whose ack or timeout brought no refund notification (still outstanding, or a success ack). The packet is
    /// authenticated against its send record's commitment; the notification is `onTimeoutPacket` (the packet was
    /// not delivered), delivered once with capped gas; false if the sender reverted, and anyone calls again.
    function notifySettled(IICS26RouterMsgs.Packet calldata packet) external returns (bool);
    /// @notice Makes the send record of a packet sent before the fork was installed, while the router still holds
    /// its commitment (which authenticates the packet). Permissionless.
    function backfill(IICS26RouterMsgs.Packet calldata packet) external;

    /// @notice Permissionless: proves a send record's destination outcome through its route's replacement client
    /// (the route's current client id; the record's client id must be retired). The packet is authenticated against
    /// the record's commitment; gno.land's receipt is recomputed from it (R19: sha256(0x03 | uint64be(sequence) |
    /// sha256(sourceClient) | packet commitment)) and compared with the proven one. A non-receipt counts only once
    /// the proven time reaches the packet's timeout (it can then never be received). Proven once, before kind 12.
    function proveOutcome(
        IICS26RouterMsgs.Packet calldata packet,
        OutcomeProof calldata proof
    )
        external
        returns (Proven);

    /// @notice gno.land's receipt value for `packet` (ADR R19; `types.CommitPacketReceipt` in gno-realms).
    function gnoReceipt(IICS26RouterMsgs.Packet calldata packet) external pure returns (bytes32);

    // ------------------------------------------------------------------------------------------- guardians --

    function setRouteFlag(string calldata clientId) external;
    function clearRouteFlag(string calldata clientId) external;
    /// @notice The refunds hold of §7.13: any one key's flag suspends proof-based refunds and claims on the route.
    function setRefundsFlag(string calldata clientId) external;
    function clearRefundsFlag(string calldata clientId) external;

    // ----------------------------------------------------------------------------------------------- refunds --

    /// @notice Pays queued refunds of a route and token in order, as the refund meter allows (an installment when
    /// it allows part of one). Permissionless.
    function claim(string calldata clientId, address token, uint256 maxCount) external returns (uint256 paid);

    /// @notice Retries a parked refund (as the refund meter allows, an installment if it allows part of it), under
    /// no refunds hold. Permissionless; reverts if the payment still fails.
    function claimParked(string calldata clientId, uint64 sequence) external returns (uint256 paid);

    // ------------------------------------------------------------------------------------------------- views --

    function routeKey(string calldata clientId) external view returns (string memory);
    function currentClient(string calldata routeKey_) external view returns (string memory);
    function isRetired(string calldata clientId) external view returns (bool);
    function guardianKeys() external view returns (address[6] memory);
    function routeFlags(string calldata clientId) external view returns (IGuardians.Flag[6] memory);
    function refundsFlags(string calldata clientId) external view returns (IGuardians.Flag[6] memory);
    function routeHold(string calldata clientId) external view returns (IGuardians.Flag memory);
    /// @notice The hold of the route's refunds flags (two guardian refunds flags), zero when none stands.
    function refundsHold(string calldata clientId) external view returns (IGuardians.Flag memory);
    function routePaused(string calldata clientId) external view returns (bool);
    function routeClosed(string calldata clientId) external view returns (bool);
    function routeReopening(string calldata clientId) external view returns (bool);
    /// @notice The last replacement's suspected compromise interval start, and its records still to settle.
    function suspectRecords(string calldata clientId) external view returns (uint64 from, uint64 open);
    /// @notice Losses kind 12 recorded on the route for the token.
    function losses(string calldata clientId, address token) external view returns (uint256);

    /// @notice A receive at an inbound `sequence` of `clientId`: the token released or minted and its amount (zero
    /// once kind 12 action 5 booked it as forged, or if there was none).
    function receiveRecord(string calldata clientId, uint64 sequence) external view returns (address, uint256);
    /// @notice Escrow of the token reserved for the route's owed refunds (queued, parked or decided but unpaid).
    function reserved(string calldata clientId, address token) external view returns (uint256);
    /// @notice The route's send records still open (an outstanding packet, or a refund owed not settled).
    function openRecords(string calldata clientId) external view returns (uint64);
    /// @notice The part of the route's losses of the token kind 13 accepted as a deficit.
    function acceptedDeficit(string calldata clientId, address token) external view returns (uint256);
    function refundsHeld(string calldata clientId) external view returns (bool);
    function limits(string calldata clientId, address token) external view returns (LimitsView memory);
    function quarantineSeconds(string calldata clientId) external view returns (uint64);
    function recoveryBlocked(string calldata clientId) external view returns (bool);
    function sendRecord(string calldata clientId, uint64 sequence) external view returns (SendRecord memory);
    function refundQueue(string calldata clientId, address token) external view returns (uint64 head, uint64 tail);
}
