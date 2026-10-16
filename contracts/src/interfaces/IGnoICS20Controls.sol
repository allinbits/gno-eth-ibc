// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

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

    /// @notice The refund state of a send record: none owed, paid at once, queued under the refund meter or the
    /// refunds hold, paid in full by `claim`, or parked: its payment reverted (a token that refuses the sender, a
    /// paused token), so it waits apart and `claimParked` retries it, and no other refund waits behind it.
    enum Payment {
        None,
        Paid,
        Queued,
        Claimed,
        Parked
    }

    /// @notice The per-packet send record (§7.13), keyed by (source client id, sequence). Written by every send
    /// variant after the router returned the sequence; the ack and timeout callbacks only attach the outcome, the
    /// local processing block and the payment state. `commitment` is the router's packet commitment, which binds
    /// the full packet (timeout and payload; the packet itself is in the router's SendPacket event). A record with a
    /// zero commitment was created by a callback for a packet sent before the upgrade.
    struct SendRecord {
        bytes32 commitment;
        address sender;
        address token;
        address escrow;
        uint64 timeoutTimestamp;
        uint64 sendBlock;
        uint64 processedBlock;
        bool burned;
        Outcome outcome;
        Payment payment;
        uint256 amount;
        uint256 refunded;
    }

    // ------------------------------------------------------------------------------------- expected refusals --
    // The router turns a receive callback's revert with non-empty data into an error acknowledgement, which
    // refunds the sender at the source.

    error GnoClientRetired(string clientId);
    error GnoRoutePaused(string clientId);
    error GnoRouteRecovering(string clientId);
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
    /// @notice Clears the route's flags and refunds flags set at a block before `beforeBlock`; refused under a hold
    /// of the route's flags (IGuardians.HoldStands).
    function unpauseRoute(string calldata clientId, uint64 beforeBlock) external returns (uint256 cleared);
    /// @notice Refuses (or allows again) every token receive on the route while an emergency recovery is open.
    function setRecoveryBlock(string calldata clientId, bool blocked) external;
    /// @notice Points `newClientId` at `oldClientId`'s route and retires `oldClientId` (constant work).
    function migrateRoute(string calldata oldClientId, string calldata newClientId) external;

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
    function routePaused(string calldata clientId) external view returns (bool);
    function refundsHeld(string calldata clientId) external view returns (bool);
    function limits(string calldata clientId, address token) external view returns (LimitsView memory);
    function quarantineSeconds(string calldata clientId) external view returns (uint64);
    function recoveryBlocked(string calldata clientId) external view returns (bool);
    function sendRecord(string calldata clientId, uint64 sequence) external view returns (SendRecord memory);
    function refundQueue(string calldata clientId, address token) external view returns (uint64 head, uint64 tail);
}
