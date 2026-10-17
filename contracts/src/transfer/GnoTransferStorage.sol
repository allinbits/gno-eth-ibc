// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import { Bytes } from "@openzeppelin-contracts/utils/Bytes.sol";
import { IEscrow } from "@eureka/interfaces/IEscrow.sol";
import { IMintableAndBurnable } from "@eureka/interfaces/IMintableAndBurnable.sol";
import { ICS20Lib } from "@eureka/utils/ICS20Lib.sol";

import { ERC165Checker } from "@openzeppelin-contracts/utils/introspection/ERC165Checker.sol";
import { IIBCSenderCallbacks } from "@eureka/interfaces/IIBCSenderCallbacks.sol";

import { IICS02Client } from "@eureka/interfaces/IICS02Client.sol";
import { IGnoLightClientStatus } from "../interfaces/IGnoLightClientStatus.sol";
import { IGnoICS20ControlsTypes } from "../interfaces/IGnoICS20Controls.sol";
import { Guardians } from "../lib/Guardians.sol";
import { LeakyBucket } from "../lib/LeakyBucket.sol";

/// @title The state GnoICS20Transfer and GnoICS20Controls share
/// @notice One ERC-7201 namespace (`gno.storage.GnoICS20Transfer`), apart from eureka's ICS20Transfer namespace, so
/// the fork's state is append-only to a deployed ICS20Transfer proxy. GnoICS20Controls runs by delegatecall from
/// GnoICS20Transfer, so both read the proxy's storage through this layout.
library GnoTransferStorage {
    /// @notice Grace of a route hold's dip (24 hours, §7.4).
    uint64 internal constant GRACE = 1 days;

    /// @notice One route's flags (pause and refunds hold) and settings.
    struct Route {
        Guardians.Flags flags;
        Guardians.Flags refundFlags;
        uint64 quarantineSeconds;
        bool recoveryBlocked;
        /// Closed by a route replacement (kind 10 or the emergency recovery) until reopened by kind 13: no receive,
        /// no send, no claim.
        bool closed;
        /// The deadline the transitions already seen set, each with the duration in force when it was accepted, and
        /// the latest transition seen (client and transition number) when a duration last changed.
        uint64 quarantineDeadline;
        address seenClient;
        uint64 seenTransition;
        /// Tokens kind 12 recorded a loss of (each once), for kind 13's accepted deficits.
        address[] lossTokens;
        /// Kind 13 under way: its deficits are accepted in batches from `deficitCursor`; the route opens with the last.
        bool reopening;
        uint64 deficitCursor;
        /// Bumped whenever the route's client may be re-pointed (a verifier swap, a replacement): an outcome proven
        /// under an earlier generation is void, even if the same client comes back.
        uint64 verifierGen;
        /// The route's incidents (closures), appended; every one below `resolvedUpTo` is resolved. The route is
        /// open only when all are (docs/controls.md, the reconciliation state machine).
        IGnoICS20ControlsTypes.Incident[] incidents;
        uint64 resolvedUpTo;
        /// Incidents below it (from `resolvedUpTo`) are reopening: kind 13 under way. Statuses are derived from the
        /// two bounds, so no transition walks the incidents.
        uint64 reopenUpTo;
        /// Unresolved replacement incidents whose client still has an open or unsettled suspect record: kind 13
        /// waits for zero (kept by every change of those counts, so no transition walks the incidents).
        uint64 pendingIncidents;
    }

    /// @notice Incident kinds and statuses.
    uint8 internal constant REPLACEMENT = 1;
    uint8 internal constant LATE_LOSS = 2;
    uint8 internal constant OPEN = 1;
    uint8 internal constant REOPENING = 2;
    uint8 internal constant RESOLVED = 3;

    /// @notice One client id of a route (a generation): the blocks at which its acks and timeouts were processed
    /// (append-only; a record keeps its index), its open records, and once retired the incident covering it, the
    /// first suspect index and how many of its records processed from there on are unsettled.
    struct ClientRecon {
        uint64[] processed;
        uint64 open;
        uint32 incident;
        uint64 suspectStart;
        uint64 suspectOpen;
        bytes32 route;
    }

    /// @notice A refund queued under the refund meter or the refunds hold: its send record.
    struct QueuedRefund {
        string clientId;
        uint64 sequence;
    }

    /// @notice One route's controls for one token, with its queue of refunds.
    struct TokenControls {
        bool set;
        IGnoICS20ControlsTypes.Limits limits;
        LeakyBucket.Bucket received;
        LeakyBucket.Bucket refunded;
        uint64 head;
        uint64 tail;
        mapping(uint64 index => QueuedRefund) queue;
        /// Escrow reserved, for an escrowed token, for refunds owed (queued, parked or decided but unpaid) and for
        /// outstanding sends, whose refund could still be owed: no receive or refund releases escrow below it (ADR
        /// §7.12). A voucher's refund mints, so it reserves nothing.
        uint256 reserved;
    }

    /// @custom:storage-location erc7201:gno.storage.GnoICS20Transfer
    struct Layout {
        /// The guardian keys (seats 0-3, watch keys 4-5): IBCAdmin's list, set by it.
        Guardians.Keys keys;
        /// A client id's route key; empty: the client id is its own route key.
        mapping(string clientId => string routeKey) routeOf;
        /// A route key's current client id; empty: the route key itself.
        mapping(string routeKey => string clientId) currentOf;
        /// Client ids whose route moved on: no send or receive.
        mapping(string clientId => bool) retired;
        mapping(bytes32 route => Route) routes;
        mapping(bytes32 route => mapping(address token => TokenControls)) tokens;
        mapping(bytes32 clientHash => mapping(uint64 sequence => IGnoICS20ControlsTypes.SendRecord)) records;
        /// The hash of a sender's notification (the IIBCSenderCallbacks calldata the router's callback carried) held
        /// until its refund is paid, or kept after a failed delivery: never its bytes.
        mapping(bytes32 clientHash => mapping(uint64 sequence => bytes32)) notices;
        /// A notification delivered or dropped: done for good.
        mapping(bytes32 clientHash => mapping(uint64 sequence => bool)) noticeDone;
        /// Losses recorded by kind 12, per route and token, and the part of them kind 13 accepted as a deficit.
        mapping(bytes32 route => mapping(address token => uint256)) losses;
        mapping(bytes32 route => mapping(address token => uint256)) acceptedDeficit;
        /// A reconciliation refund's notification (`notifySettled`, built from the authenticated packet) delivered.
        mapping(bytes32 clientHash => mapping(uint64 sequence => bool)) settledNoticeDone;
        /// Every receive, per (destination client id, inbound sequence), in one slot: the token released or minted
        /// (low 160 bits) and the amount (high 96 bits; zero once kind 12 booked it as a forged receive).
        mapping(bytes32 clientHash => mapping(uint64 sequence => uint256)) receives;
        /// The hash of the success ack `proveOutcome` proved for a delivered record (the success notification a
        /// reconciliation owes is built with it).
        mapping(bytes32 clientHash => mapping(uint64 sequence => bytes32)) provenAck;
        /// Per client id: its reconciliation counters (ClientRecon).
        mapping(bytes32 clientHash => ClientRecon) clients;
        /// Every loss booked, by its packet's canonical identity keccak256(client hash, sequence, direction): a
        /// payout is booked once, whatever the path (action 4, action 5, a late loss).
        mapping(bytes32 id => bool) lossBooked;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("gno.storage.GnoICS20Transfer")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant SLOT = 0xf3bec7e430c885c7577ab512690266d2e153034fd4fd64588d19040d96496100;

    function layout() internal pure returns (Layout storage l) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            l.slot := SLOT
        }
    }

    // ----------------------------------------------------------------------------------------- route keys --

    /// @notice A client id's route key.
    function routeKey(string memory clientId) internal view returns (string memory) {
        string memory r = layout().routeOf[clientId];
        return bytes(r).length == 0 ? clientId : r;
    }

    function routeHash(string memory clientId) internal view returns (bytes32) {
        return keccak256(bytes(routeKey(clientId)));
    }

    /// @notice `transfer/<client id>/rest` with an aliased client id as `transfer/<route key>/rest`.
    function toRouteDenom(bytes memory path) internal view returns (bytes memory) {
        (bool ok, string memory hop, uint256 end) = _firstHop(path);
        if (!ok) return path;
        string memory r = layout().routeOf[hop];
        if (bytes(r).length == 0) return path;
        return abi.encodePacked(ICS20Lib.DEFAULT_PORT_ID, "/", r, Bytes.slice(path, end));
    }

    /// @notice `transfer/<route key>/rest` of a migrated route as `transfer/<current client id>/rest`.
    function toWireDenom(bytes memory path) internal view returns (bytes memory) {
        (bool ok, string memory hop, uint256 end) = _firstHop(path);
        if (!ok) return path;
        string memory c = layout().currentOf[hop];
        if (bytes(c).length == 0) return path;
        return abi.encodePacked(ICS20Lib.DEFAULT_PORT_ID, "/", c, Bytes.slice(path, end));
    }

    /// @notice The client id of a path's first hop `transfer/<hop>/`, and where the rest (from that '/') starts.
    function _firstHop(bytes memory path) private pure returns (bool ok, string memory hop, uint256 end) {
        bytes memory port = bytes(string.concat(ICS20Lib.DEFAULT_PORT_ID, "/"));
        if (!ICS20Lib.hasPrefix(path, port)) return (false, "", 0);
        for (uint256 i = port.length; i < path.length; ++i) {
            if (path[i] == "/") return (i > port.length, string(Bytes.slice(path, port.length, i)), i);
        }
        return (false, "", 0);
    }

    // ----------------------------------------------------------------------------------------- quarantine --

    /// @notice When the route's quarantine ends (ADR §7.10, kind 11): the deadline the transitions seen when the
    /// duration last changed set, and for a later transition of the client (`lastTransition`), its time plus the
    /// duration in force now. A duration applies only to transitions accepted after it; one already started keeps
    /// its deadline. Transitions are told apart by number, never by time (two can share a block).
    function quarantineUntil(
        Route storage r,
        address client,
        uint64 transitionId,
        uint64 transitionTime
    )
        internal
        view
        returns (uint256)
    {
        uint256 until = r.quarantineDeadline;
        uint64 q = r.quarantineSeconds;
        if (q != 0 && transitionId != 0 && (client != r.seenClient || transitionId != r.seenTransition)) {
            uint256 end = uint256(transitionTime) + q;
            if (end > until) until = end;
        }
        return until;
    }

    // -------------------------------------------------------------------------------------------- refunds --

    /// @notice Whether the refunds hold stands on a route: any one key's refunds flag (§7.13).
    function refundsHeld(bytes32 route) internal view returns (bool) {
        Layout storage l = layout();
        return Guardians.anyFlag(l.keys, l.routes[route].refundFlags);
    }

    /// @notice Pays part or all of a record's refund: mints a burned voucher back into the escrow, then releases.
    /// Returns false, having changed nothing, when the token or the escrow refuses (the mint is undone), or when
    /// releasing escrow would leave less than the route's other reservations (`own` is what this record holds of
    /// `reserved` now): a refund never consumes the backing of another owed refund or outstanding send (§7.12).
    function tryPayRefund(
        IGnoICS20ControlsTypes.SendRecord storage rec,
        uint256 amount,
        bytes32 route,
        uint256 own,
        uint256 budget
    )
        internal
        returns (bool)
    {
        address token = rec.token;
        address escrow = rec.escrow;
        bool burned = rec.burned;
        // a bounded payment gives the token PAY_GAS per call: one that runs out on its own is parked, never taking
        // the transaction (or a settlement's batch) down; with less gas left than the payment needs, the caller is
        // starving it, and the whole call reverts (to be retried) instead
        // `budget` zero: the automatic bound (PAY_GAS per call, BALANCE_GAS for the balance read); a caller-funded
        // retry (`claimParked`) chooses a larger one, for the balance read and each call alike
        uint256 g = budget == 0 ? PAY_GAS : (budget < PAY_GAS ? PAY_GAS : budget);
        uint256 gb = budget == 0 ? BALANCE_GAS : g;
        if (gasleft() < (gb + 2 * g) * 64 / 63 + 100_000) revert IGnoICS20ControlsTypes.GnoPaymentStarved();
        bool ok;
        bytes memory ret;
        if (!burned) {
            // the escrow keeps the route's other reservations: subtractions only, each guarded
            uint256 others = layout().tokens[route][token].reserved - own;
            (ok, ret) = token.staticcall{ gas: gb }(abi.encodeCall(IERC20.balanceOf, (escrow)));
            if (!ok || ret.length != 32) return false;
            uint256 balance = abi.decode(ret, (uint256));
            if (balance < amount || balance - amount < others) return false;
        }
        if (burned) {
            (ok,) = token.call{ gas: g }(abi.encodeCall(IMintableAndBurnable.mint, (escrow, amount)));
            if (!ok) return false;
        }
        (ok,) = escrow.call{ gas: g }(abi.encodeCall(IEscrow.send, (IERC20(token), rec.sender, amount)));
        if (!ok) {
            // the voucher is governance-pinned code: its burn undoing the mint is not bounded
            if (burned) IMintableAndBurnable(token).burn(escrow, amount);
            return false;
        }
        rec.refunded += amount;
        return true;
    }

    /// @notice The gas a bounded payment gives each token or escrow call, the gas a balance read gets, and the gas a
    /// bounded payment needs left to start (both calls in full, and what follows them).
    uint256 internal constant PAY_GAS = 200_000;
    uint256 internal constant BALANCE_GAS = 30_000;
    uint256 internal constant PAY_NEED = (BALANCE_GAS + 2 * PAY_GAS) * 64 / 63 + 100_000;

    // ------------------------------------------------------------------------------------------ open records --

    /// @notice A record of client `clientHash` now open (written by a send).
    function openRecord(IGnoICS20ControlsTypes.SendRecord storage rec, bytes32 clientHash) internal {
        rec.open = true;
        ClientRecon storage c = layout().clients[clientHash];
        bool had = hasWork(c);
        ++c.open;
        noteWork(c, had);
    }

    /// @notice A record closed: its packet acknowledged with success, its refund paid in full, or settled by kind 12.
    function closeRecord(IGnoICS20ControlsTypes.SendRecord storage rec, bytes32 clientHash) internal {
        if (!rec.open) return;
        rec.open = false;
        ClientRecon storage c = layout().clients[clientHash];
        bool had = hasWork(c);
        --c.open;
        noteWork(c, had);
    }

    // ---------------------------------------------------------------------------------------------- incidents --

    /// @notice Whether a client id still has reconciliation work: an open record or an unsettled suspect one.
    function hasWork(ClientRecon storage c) internal view returns (bool) {
        return c.open != 0 || c.suspectOpen != 0;
    }

    /// @notice Keeps its route's pending-incident count after a change of a retired client's work (`had` before):
    /// constant work, only for an unresolved incident.
    function noteWork(ClientRecon storage c, bool had) internal {
        if (c.incident == 0) return;
        bool has = hasWork(c);
        if (had == has) return;
        Route storage r = layout().routes[c.route];
        if (c.incident - 1 < r.resolvedUpTo) return;
        if (has) ++r.pendingIncidents;
        else --r.pendingIncidents;
    }

    /// @notice An incident's status, from the route's two bounds.
    function incidentStatus(Route storage r, uint256 i) internal view returns (uint8) {
        if (i < r.resolvedUpTo) return RESOLVED;
        return i < r.reopenUpTo ? REOPENING : OPEN;
    }

    /// @notice Aborts a reopening under way (constant work): its incidents open again, the route stays closed.
    function abortReopening(Route storage r, string memory key) internal {
        if (!r.reopening) return;
        r.reopening = false;
        r.reopenUpTo = r.resolvedUpTo;
        emit IGnoICS20ControlsTypes.GnoReopenAborted(key);
    }

    // ---------------------------------------------------------------------------------------- reservations --

    /// @notice The escrow a record reserves, for an escrowed token: an owed refund's unpaid remainder (queued or
    /// parked), or an outstanding send's whole amount (no ack or timeout yet, not settled), whose refund could still
    /// be owed. A voucher's refund mints, so it reserves nothing.
    function reservation(IGnoICS20ControlsTypes.SendRecord storage rec) internal view returns (uint256) {
        if (rec.burned) return 0;
        IGnoICS20ControlsTypes.Payment pay = rec.payment;
        if (pay == IGnoICS20ControlsTypes.Payment.Queued || pay == IGnoICS20ControlsTypes.Payment.Parked) {
            return rec.amount - rec.refunded;
        }
        bool outstanding = rec.outcome == IGnoICS20ControlsTypes.Outcome.Pending && rec.settlement == 0;
        return outstanding ? rec.amount : 0;
    }

    /// @notice Moves the route's reservation of the record's token from `before` to the record's reservation now.
    function syncReserve(bytes32 route, IGnoICS20ControlsTypes.SendRecord storage rec, uint256 before) internal {
        TokenControls storage t = layout().tokens[route][rec.token];
        t.reserved = t.reserved - before + reservation(rec);
    }

    /// @notice The route's replacement client if active (neither frozen nor expired), else zero.
    function activeClient(string memory clientId) internal view returns (address) {
        string memory current = layout().currentOf[GnoTransferStorage.routeKey(clientId)];
        address lc = address(IICS02Client(ics20Router()).getClient(current));
        if (IGnoLightClientStatus(lc).isFrozen() || IGnoLightClientStatus(lc).isExpired()) return address(0);
        return lc;
    }

    // ------------------------------------------------------------------------------------------- receives --

    /// @notice Records a receive's token and amount (an amount above 96 bits is refused before: never truncated).
    function recordReceive(string memory clientId, uint64 sequence, address token, uint256 amount) internal {
        layout().receives[keccak256(bytes(clientId))][sequence] = (amount << 160) | uint160(token);
    }

    // ---------------------------------------------------------------------------------------- notifications --

    /// @notice The gas a sender's callback gets, and the gas kept back for the rest of the transaction: a callback
    /// that burns its gas never takes a settlement down with it.
    uint256 internal constant CALLBACK_GAS = 100_000;
    uint256 internal constant CALLBACK_RESERVE = 60_000;

    /// @notice Delivers a sender's IIBCSenderCallbacks notification, if it takes them. A failure never rolls a refund
    /// back: the notification is kept (its hash) for `retryNotification`.
    function notify(address sender, bytes memory call, string memory clientId, uint64 sequence) internal {
        if (!ERC165Checker.supportsInterface(sender, type(IIBCSenderCallbacks).interfaceId)) return;
        _deliver(sender, call, clientId, sequence);
    }

    /// @notice Holds a notification until the refund it announces is paid (only for senders that take them). Only
    /// its hash is stored: constant work whatever the packet's size; whoever delivers it supplies the bytes.
    function holdNotice(address sender, bytes memory call, string memory clientId, uint64 sequence) internal {
        if (!ERC165Checker.supportsInterface(sender, type(IIBCSenderCallbacks).interfaceId)) return;
        layout().notices[keccak256(bytes(clientId))][sequence] = keccak256(call);
    }

    /// @notice A held notification's refund is paid in full: the notification is due (`retryNotification`
    /// delivers it with its bytes). Constant work.
    function releaseNotice(string memory clientId, uint64 sequence) internal {
        bytes32 h = keccak256(bytes(clientId));
        if (layout().notices[h][sequence] != bytes32(0) && !layout().noticeDone[h][sequence]) {
            emit IGnoICS20ControlsTypes.GnoNotificationDue(clientId, sequence);
        }
    }

    /// @notice Drops a held notification for good (its refund was rejected).
    function dropNotice(string memory clientId, uint64 sequence) internal {
        layout().noticeDone[keccak256(bytes(clientId))][sequence] = true;
    }

    /// @notice Calls the sender with CALLBACK_GAS, and only with CALLBACK_RESERVE left beyond it. Delivered, the
    /// notification is marked done; not delivered, its hash is kept.
    function _deliver(
        address sender,
        bytes memory call,
        string memory clientId,
        uint64 sequence
    )
        private
        returns (bool ok)
    {
        return _deliverWith(sender, call, clientId, sequence, 0);
    }

    /// @notice As `_deliver`, with `budget` gas when non-zero (a caller-funded retry: at least CALLBACK_GAS, and
    /// the caller must send enough for all of it and the reserve, or it reverts as starved).
    function _deliverWith(
        address sender,
        bytes memory call,
        string memory clientId,
        uint64 sequence,
        uint256 budget
    )
        private
        returns (bool ok)
    {
        uint256 g = _budget(budget);
        if (gasleft() >= g * 64 / 63 + CALLBACK_RESERVE) (ok,) = sender.call{ gas: g }(call);
        bytes32 h = keccak256(bytes(clientId));
        if (ok) layout().noticeDone[h][sequence] = true;
        else layout().notices[h][sequence] = keccak256(call);
        emit IGnoICS20ControlsTypes.GnoSenderNotified(clientId, sequence, ok);
    }

    /// @notice Delivers the notification of a refund kind 12 paid for a packet whose ack or timeout never brought one
    /// (`notifySettled`): built from the authenticated packet, never stored, delivered once, retried by calling again.
    function deliverSettled(
        address sender,
        bytes memory call,
        string memory clientId,
        uint64 sequence,
        uint256 budget
    )
        internal
        returns (bool ok)
    {
        bytes32 h = keccak256(bytes(clientId));
        if (
            layout().settledNoticeDone[h][sequence]
                || !ERC165Checker.supportsInterface(sender, type(IIBCSenderCallbacks).interfaceId)
        ) revert IGnoICS20ControlsTypes.GnoNoNotification(clientId, sequence);
        uint256 g = _budget(budget);
        (ok,) = sender.call{ gas: g }(call);
        if (ok) layout().settledNoticeDone[h][sequence] = true;
        emit IGnoICS20ControlsTypes.GnoSenderNotified(clientId, sequence, ok);
    }

    /// @notice Retries a kept notification of a record whose outcome is final for the sender (a success ack, or a
    /// refund paid in full), given its bytes, authenticated against the kept hash; it only calls the sender, so it
    /// can never pay twice.
    function retryNotice(
        IGnoICS20ControlsTypes.SendRecord storage rec,
        string memory clientId,
        uint64 sequence,
        bytes calldata call,
        uint256 budget
    )
        internal
        returns (bool)
    {
        bytes32 h = keccak256(bytes(clientId));
        IGnoICS20ControlsTypes.Payment pay = rec.payment;
        bool due = rec.outcome == IGnoICS20ControlsTypes.Outcome.Success || pay == IGnoICS20ControlsTypes.Payment.Paid
            || pay == IGnoICS20ControlsTypes.Payment.Claimed;
        bytes32 kept = layout().notices[h][sequence];
        if (kept == bytes32(0) || kept != keccak256(call) || layout().noticeDone[h][sequence] || !due) {
            revert IGnoICS20ControlsTypes.GnoNoNotification(clientId, sequence);
        }
        _budget(budget); // starved callers revert before anything
        return _deliverWith(rec.sender, call, clientId, sequence, budget);
    }

    /// @notice A caller-funded notification's gas: `budget`, at least CALLBACK_GAS; reverts if the caller did not
    /// send enough for it and the reserve (zero: the automatic CALLBACK_GAS, never reverting).
    function _budget(uint256 budget) private view returns (uint256) {
        if (budget == 0) return CALLBACK_GAS;
        if (budget < CALLBACK_GAS) budget = CALLBACK_GAS;
        if (gasleft() < budget * 64 / 63 + CALLBACK_RESERVE) revert IGnoICS20ControlsTypes.GnoNotificationStarved();
        return budget;
    }

    /// @notice A record's transport notification kind (0 none, 1 success, 2 refund) and the terminal kind its
    /// settlement decides (0 not settled; action 1 a refund, actions 2-4 a success: the packet was delivered).
    function noticeKinds(IGnoICS20ControlsTypes.SendRecord storage rec)
        internal
        view
        returns (uint8 transport, uint8 terminal)
    {
        IGnoICS20ControlsTypes.Outcome o = rec.outcome;
        transport =
            o == IGnoICS20ControlsTypes.Outcome.Success ? 1 : (o == IGnoICS20ControlsTypes.Outcome.Pending ? 0 : 2);
        uint8 s = rec.settlement;
        terminal = s == 0 ? 0 : (s == 1 ? 2 : 1);
    }

    /// @notice What a record may still be refunded: its amount less what was refunded.
    function refundable(IGnoICS20ControlsTypes.SendRecord storage rec) internal view returns (uint256) {
        return rec.amount - rec.refunded;
    }

    // ------------------------------------------------------------------------- eureka's ICS20Transfer state --

    /// @notice eureka ICS20Transfer's ERC-7201 namespace (`ibc.storage.ICS20Transfer`): `_escrows`,
    /// `_ibcERC20Contracts`, `_ibcERC20Denoms`, `_ics26`, ...
    uint256 internal constant ICS20_SLOT = 0x823f7a8ea9ae6df0eb03ec5e1682d7a2839417ad8a91774118e6acf2e8d2f800;

    /// @notice `_ics26`, the router.
    function ics20Router() internal view returns (address router) {
        uint256 slot = ICS20_SLOT + 3;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            router := sload(slot)
        }
    }

    /// @notice `_ibcERC20Contracts[denom]`.
    function ics20Registered(string memory denom) internal view returns (address token) {
        bytes32 slot = keccak256(abi.encodePacked(denom, ICS20_SLOT + 1));
        // solhint-disable-next-line no-inline-assembly
        assembly {
            token := sload(slot)
        }
    }

    /// @notice `_escrows[key]`.
    function ics20Escrow(string memory key) internal view returns (address escrow) {
        bytes32 slot = keccak256(abi.encodePacked(key, ICS20_SLOT));
        // solhint-disable-next-line no-inline-assembly
        assembly {
            escrow := sload(slot)
        }
    }
}
