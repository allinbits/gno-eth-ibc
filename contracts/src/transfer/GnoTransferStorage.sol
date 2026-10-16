// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import { Bytes } from "@openzeppelin-contracts/utils/Bytes.sol";
import { IEscrow } from "@eureka/interfaces/IEscrow.sol";
import { IMintableAndBurnable } from "@eureka/interfaces/IMintableAndBurnable.sol";
import { ICS20Lib } from "@eureka/utils/ICS20Lib.sol";

import { ERC165Checker } from "@openzeppelin-contracts/utils/introspection/ERC165Checker.sol";
import { IIBCSenderCallbacks } from "@eureka/interfaces/IIBCSenderCallbacks.sol";

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
        /// the latest transition seen (client and time) when a duration last changed.
        uint64 quarantineDeadline;
        address seenClient;
        uint64 seenTransition;
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
        /// A sender's notification (IIBCSenderCallbacks calldata) held until its refund is paid.
        mapping(bytes32 clientHash => mapping(uint64 sequence => bytes)) notices;
        /// Losses recorded by kind 12, per route and token.
        mapping(bytes32 route => mapping(address token => uint256)) losses;
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
    /// its deadline.
    function quarantineUntil(Route storage r, address client, uint64 lastTransition) internal view returns (uint256) {
        uint256 until = r.quarantineDeadline;
        uint64 q = r.quarantineSeconds;
        if (q != 0 && lastTransition != 0 && (client != r.seenClient || lastTransition != r.seenTransition)) {
            uint256 end = uint256(lastTransition) + q;
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
    /// Returns false, having changed nothing, when the token or the escrow refuses (the mint is undone).
    function tryPayRefund(IGnoICS20ControlsTypes.SendRecord storage rec, uint256 amount) internal returns (bool) {
        address token = rec.token;
        address escrow = rec.escrow;
        bool burned = rec.burned;
        bool ok;
        if (burned) {
            (ok,) = token.call(abi.encodeCall(IMintableAndBurnable.mint, (escrow, amount)));
            if (!ok) return false;
        }
        (ok,) = escrow.call(abi.encodeCall(IEscrow.send, (IERC20(token), rec.sender, amount)));
        if (!ok) {
            if (burned) IMintableAndBurnable(token).burn(escrow, amount);
            return false;
        }
        rec.refunded += amount;
        return true;
    }

    // ---------------------------------------------------------------------------------------- notifications --

    /// @notice Delivers a sender's IIBCSenderCallbacks notification, if it takes them; its failure is recorded and
    /// never rolls a refund back.
    function notify(address sender, bytes memory call, string memory clientId, uint64 sequence) internal {
        if (!ERC165Checker.supportsInterface(sender, type(IIBCSenderCallbacks).interfaceId)) return;
        (bool ok,) = sender.call(call);
        emit IGnoICS20ControlsTypes.GnoSenderNotified(clientId, sequence, ok);
    }

    /// @notice Holds a notification until the refund it announces is paid (only for senders that take them).
    function holdNotice(address sender, bytes memory call, string memory clientId, uint64 sequence) internal {
        if (!ERC165Checker.supportsInterface(sender, type(IIBCSenderCallbacks).interfaceId)) return;
        layout().notices[keccak256(bytes(clientId))][sequence] = call;
    }

    /// @notice Delivers a held notification once its refund is paid in full.
    function releaseNotice(
        IGnoICS20ControlsTypes.SendRecord storage rec,
        string memory clientId,
        uint64 sequence
    )
        internal
    {
        mapping(uint64 => bytes) storage n = layout().notices[keccak256(bytes(clientId))];
        bytes memory call = n[sequence];
        if (call.length == 0) return;
        delete n[sequence];
        (bool ok,) = rec.sender.call(call);
        emit IGnoICS20ControlsTypes.GnoSenderNotified(clientId, sequence, ok);
    }

    /// @notice What a record may still be refunded: its entitlement (kind 12) or its amount, less what was refunded.
    function refundable(IGnoICS20ControlsTypes.SendRecord storage rec) internal view returns (uint256) {
        uint256 cap = rec.settlement == 1 ? rec.entitlement : rec.amount;
        return cap > rec.refunded ? cap - rec.refunded : 0;
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
