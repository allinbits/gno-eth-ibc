// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import { Bytes } from "@openzeppelin-contracts/utils/Bytes.sol";
import { IEscrow } from "@eureka/interfaces/IEscrow.sol";
import { IMintableAndBurnable } from "@eureka/interfaces/IMintableAndBurnable.sol";
import { ICS20Lib } from "@eureka/utils/ICS20Lib.sol";

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
        address[6] keys;
        /// A client id's route key; empty: the client id is its own route key.
        mapping(string clientId => string routeKey) routeOf;
        /// A route key's current client id; empty: the route key itself.
        mapping(string routeKey => string clientId) currentOf;
        /// Client ids whose route moved on: no send or receive.
        mapping(string clientId => bool) retired;
        mapping(bytes32 route => Route) routes;
        mapping(bytes32 route => mapping(address token => TokenControls)) tokens;
        mapping(bytes32 clientHash => mapping(uint64 sequence => IGnoICS20ControlsTypes.SendRecord)) records;
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

    // -------------------------------------------------------------------------------------------- refunds --

    /// @notice Whether the refunds hold stands on a route: any one key's refunds flag (§7.13).
    function refundsHeld(bytes32 route) internal view returns (bool) {
        Layout storage l = layout();
        return Guardians.anyFlag(l.keys, l.routes[route].refundFlags);
    }

    /// @notice Pays part or all of a record's refund: mints a burned voucher back into the escrow, then releases.
    function payRefund(IGnoICS20ControlsTypes.SendRecord storage rec, uint256 amount) internal {
        rec.refunded += amount;
        if (rec.burned) IMintableAndBurnable(rec.token).mint(rec.escrow, amount);
        IEscrow(rec.escrow).send(IERC20(rec.token), rec.sender, amount);
    }
}
