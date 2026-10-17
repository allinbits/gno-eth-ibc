// SPDX-License-Identifier: LicenseRef-GNO-Network-GPL
pragma solidity ^0.8.28;

// Ported in part from gnolang/bridges (branch ethereum-draft), ethereum/bridge/contracts/src/admin/HlAdminStorage.sol
// (`noteHoldEnd`, the hold history) and HlAdmin.sol (`_addCancelled`, the bounded merged ranges).
// Copyright (C) 2026 NewTendermint, LLC. GNO Network General Public License: see contracts/licenses/.

import { IICS02Client, IICS02ClientAccessControlled } from "@eureka/interfaces/IICS02Client.sol";
import { IICS02ClientMsgs } from "@eureka/msgs/IICS02ClientMsgs.sol";

import { IIBCAdmin } from "../interfaces/IIBCAdmin.sol";
import { IGuardians } from "../interfaces/IGuardians.sol";
import { Guardians } from "../lib/Guardians.sol";

/// @title IBCAdmin's state, at one ERC-7201 namespace (`gno.storage.IBCAdmin`) that IBCAdmin and the executor it
/// delegatecalls (IBCAdminExec) both read
/// @notice Every decision, buffer slot and tombstone is keyed by (epoch, seq): opening an epoch (route replacement)
/// drops the old epoch's unexecuted state in constant work.
library IBCAdminStorage {
    // ---------------------------------------------------------------------------------------------- protocol --

    uint8 internal constant ENVELOPE_VERSION = 1;
    uint256 internal constant HEADER = 14; // version u8 | epoch u32 | seq u64 | kind u8
    /// @notice The longest envelope. ADR §5.4 says 512 bytes, but a kind 6 carrying gno.land's two-element merkle
    /// prefix (`main`, `/pv/vm:gno.land/r/aib/ibc/core:`) already encodes to 558 bytes, so the bound is 1024.
    uint256 internal constant MAX_ENVELOPE = 1024;
    /// @notice The window: a packet up to `last + W` is buffered; beyond it, refused (an error ack).
    uint64 internal constant WINDOW = 64;
    /// @notice The most buffered decisions recorded per call.
    uint256 internal constant DRAIN = 8;
    /// @notice The most stored tombstone ranges of an epoch; past it, the nearest merge.
    uint256 internal constant MAX_TOMBSTONES = 64;
    /// @notice The most ranges one cancel names.
    uint256 internal constant MAX_CANCEL_RANGES = 16;
    /// @notice The hold history's bound: a ninth hold merges the two oldest.
    uint256 internal constant MAX_HOLDS = 8;

    // app acknowledgement status
    uint8 internal constant STATUS_RECORDED = 1;
    uint8 internal constant STATUS_BUFFERED = 2;
    uint8 internal constant STATUS_DUPLICATE = 3;
    uint8 internal constant STATUS_CONFLICT = 4;
    uint8 internal constant STATUS_SPENT = 5;

    // decision state
    uint8 internal constant NONE = 0;
    uint8 internal constant BUFFERED = 1;
    uint8 internal constant PENDING = 2;
    uint8 internal constant EXECUTED = 3;
    uint8 internal constant SPENT = 4;
    uint8 internal constant CANCELLED = 5;

    /// @notice An enabled emergency recovery's shortest public delay (ADR §7.12 step 3, "a long public delay"):
    /// the time everyone has to see an opened recovery and the guardians to cancel it.
    uint64 internal constant MIN_RECOVERY_DELAY = 30 days;

    /// @notice The most items a kind 12 settles.
    uint256 internal constant MAX_SETTLE_ITEMS = 8;

    // kinds (§5.4)
    uint8 internal constant KIND_CANCEL = 1;
    uint8 internal constant KIND_UNPAUSE = 2;
    uint8 internal constant KIND_SEATS = 3;
    uint8 internal constant KIND_LIMITS = 4;
    uint8 internal constant KIND_VOUCHER = 5;
    uint8 internal constant KIND_CLIENT = 6;
    uint8 internal constant KIND_UPGRADE = 7;
    uint8 internal constant KIND_ROLE = 8;
    uint8 internal constant KIND_HANDOVER = 9;
    uint8 internal constant KIND_ROUTE = 10;
    uint8 internal constant KIND_SETTINGS = 11;
    uint8 internal constant KIND_SETTLE = 12;
    uint8 internal constant KIND_REOPEN = 13;

    // atRecording's answer
    uint8 internal constant WAIT = 0;
    uint8 internal constant DONE_NOW = 1;
    uint8 internal constant SPEND = 2;

    /// @notice The gas the executor gets at recording and for each call whose failure spends a decision at
    /// execution; with less than the floor left, the call is not made and the transaction reverts.
    uint256 internal constant RECORD_GAS = 1_000_000;
    uint256 internal constant RECORD_FLOOR = RECORD_GAS * 64 / 63 + 10_000;

    /// @notice 24 hours: the unpause delay and the dip's grace.
    uint64 internal constant DAY = 1 days;
    /// @notice The decision delay.
    uint64 internal constant WEEK = 7 days;
    /// @notice A guardian replacement lands through a hold no sooner than this after the hold's start.
    uint64 internal constant HOLD_REPLACEMENT = 21 days;

    /// @notice The emergency route replacement (§7.12): each guardian seat approves one proposal (its hash); a
    /// proposal opens once enough seats approve it while the route is eligible, and executes after the delay unless
    /// enough seats vote to cancel it.
    struct Recovery {
        bytes32[4] approved;
        /// The open proposal (zero: none open), when it opened, and the seats voting to cancel it (bitmap).
        bytes32 proposal;
        uint64 openedAt;
        uint8 cancels;
        mapping(bytes32 proposal => bytes) params;
    }

    /// @custom:storage-location erc7201:gno.storage.IBCAdmin
    struct Layout {
        uint32 epoch;
        uint64 lastSeq;
        /// The block time of the last recorded decision (or of the epoch's opening): the channel's silence.
        uint64 lastRecordTime;
        /// A conflict's flag on IBCAdmin: the block it was raised at (zero: none). Cleared by an unpause decision
        /// recorded after it, or by a new epoch.
        uint64 conflictBlock;
        bool setupDone;
        /// The executor IBCAdmin delegatecalls, and the code hash it must have.
        address exec;
        bytes32 execHash;
        /// The current epoch's client id (the router's client of the gno.land chain).
        string govClient;
        mapping(uint32 epoch => mapping(uint64 seq => IIBCAdmin.Decision)) decisions;
        mapping(uint32 epoch => uint64[2][]) tombstones;
        Guardians.State g;
        IGuardians.Hold[] holds;
        Recovery recovery;
        /// The number of the decision that last set a setting (limits of a route and token, a route's quarantine),
        /// keyed by (epoch, setting): an older decision maturing later never overwrites a newer one.
        mapping(bytes32 setting => uint64 seq) appliedSeq;
        /// gno.land's chain id (an emergency recovery's client must follow it).
        string gnoChainId;
        /// Client ids a kind 6 op 1 added (custom, verifier pinned): the only targets of a kind 10.
        mapping(bytes32 clientHash => bool) enrolled;
        /// Each epoch's notice (§7.12), kept per epoch so that every one stays re-sendable after consecutive
        /// replacements: none at launch (epoch 1).
        mapping(uint32 epoch => Notice) notices;
    }

    /// @notice An epoch's notice: owed since its epoch opened by kind 10 or the emergency recovery, the client it
    /// travels over (the epoch's), whether gno.land acknowledged it, and its last send's sequence (zero: none).
    struct Notice {
        bool owed;
        bool acked;
        uint64 seq;
        string client;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("gno.storage.IBCAdmin")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant SLOT = 0xc7b243561409e24cdf9051e7d85f7a9f9509cfb6b2d07b504ea2d9365e700c00;

    function layout() internal pure returns (Layout storage l) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            l.slot := SLOT
        }
    }

    // -------------------------------------------------------------------------------------------- the kinds --

    /// @notice gno.land's IBC store and key prefix: the only counterparty merkle prefix a client may be given.
    bytes internal constant GNO_STORE = "main";
    bytes internal constant GNO_KEY_PREFIX = "/pv/vm:gno.land/r/aib/ibc/core:";

    /// @notice A counterparty in canonical form: gno.land's exact merkle prefix, and a client id of 1 to 64
    /// characters in [a-z0-9-].
    function canonicalCounterparty(string memory clientId, bytes[] memory prefix) internal pure returns (bool) {
        bytes memory b = bytes(clientId);
        if (b.length == 0 || b.length > 64) return false;
        for (uint256 i = 0; i < b.length; i++) {
            bytes1 c = b[i];
            if (!((c >= "a" && c <= "z") || (c >= "0" && c <= "9") || c == "-")) return false;
        }
        return prefix.length == 2 && keccak256(prefix[0]) == keccak256(GNO_STORE)
            && keccak256(prefix[1]) == keccak256(GNO_KEY_PREFIX);
    }

    /// @notice A gno.land denom in exactly the wire grammar shared with gno.land's ibcgov builder
    /// (`isGnoWireDenom`), at most 128 bytes:
    ///
    /// - native: `[a-z][a-z0-9]{2,15}` (e.g. `ugnot`);
    /// - GRC20 alias (gno-realms' `GRC20Alias` of a grc20reg key): the literal `gno.land:r`, then at least two
    ///   `:`-separated segments, each GnoVM's `Re_name` `[a-z][a-z0-9]*([_-][a-z0-9]+)*` (single `_` or `-`
    ///   separators, never leading, trailing or doubled), then optionally `.` and a slug of 1 to 32 bytes of
    ///   `[A-Za-z0-9_-]`.
    ///
    /// Realm-issued coins (`/gno.land/r/...:denom`) are refused: the gno side never sends them.
    function canonicalGnoDenom(string memory denom) internal pure returns (bool) {
        bytes memory b = bytes(denom);
        uint256 n = b.length;
        if (n == 0 || n > 128) return false;
        bytes memory head = "gno.land:r";
        bool isAlias = n > head.length;
        for (uint256 i = 0; isAlias && i < head.length; i++) {
            isAlias = b[i] == head[i];
        }
        if (!isAlias) {
            if (n < 3 || n > 16 || !_lower(b[0])) return false;
            for (uint256 i = 1; i < n; i++) {
                if (!_lower(b[i]) && !_digit(b[i])) return false;
            }
            return true;
        }
        uint256 j = head.length; // at the ':' before the first segment
        uint256 segs;
        while (j < n && b[j] == ":") {
            j++;
            if (j >= n || !_lower(b[j])) return false;
            j++;
            while (j < n && (_lower(b[j]) || _digit(b[j]))) j++;
            while (j < n && (b[j] == "_" || b[j] == "-")) {
                j++;
                if (j >= n || !(_lower(b[j]) || _digit(b[j]))) return false;
                while (j < n && (_lower(b[j]) || _digit(b[j]))) j++;
            }
            segs++;
        }
        if (segs < 2) return false;
        if (j == n) return true;
        if (b[j] != ".") return false;
        uint256 slug = n - j - 1;
        if (slug == 0 || slug > 32) return false;
        for (uint256 k = j + 1; k < n; k++) {
            bytes1 c = b[k];
            if (!_lower(c) && !_digit(c) && !(c >= "A" && c <= "Z") && c != "_" && c != "-") return false;
        }
        return true;
    }

    function _lower(bytes1 c) private pure returns (bool) {
        return c >= "a" && c <= "z";
    }

    function _digit(bytes1 c) private pure returns (bool) {
        return c >= "0" && c <= "9";
    }

    /// @notice The gas a kind's execution frame gets (IBCAdmin.execute): enough for every step it takes, its fixed
    /// call budgets included, so a failure inside the frame is the decision's, never the caller's (it is spent);
    /// a caller sending less than the frame needs is refused before it (the decision pends).
    function execGas(uint8 kind) internal pure returns (uint256) {
        if (kind == KIND_SETTLE) return 7_000_000;
        if (kind == KIND_UPGRADE || kind == KIND_HANDOVER) return 3_500_000;
        if (kind == KIND_ROUTE || kind == KIND_CLIENT || kind == KIND_REOPEN) return 2_500_000;
        return 1_500_000;
    }

    function knownKind(uint8 kind) internal pure returns (bool) {
        return kind >= KIND_CANCEL && kind <= KIND_REOPEN;
    }

    /// @notice Kinds suspended while an emergency recovery is open: those that change authority (§7.12; kind 10,
    /// the route replacement, conservatively too).
    function suspendedByRecovery(uint8 kind) internal pure returns (bool) {
        return kind == KIND_SEATS || (kind >= KIND_CLIENT && kind <= KIND_ROUTE);
    }

    // ---------------------------------------------------------------------------------------------- flags --

    /// @notice A flag or a hold stands on IBCAdmin, or a conflict's flag.
    function flagged(Layout storage l) internal view returns (bool) {
        return l.conflictBlock != 0 || Guardians.anyFlag(l.g.k, l.g.f);
    }

    function hold(Layout storage l) internal view returns (bool stands, uint64 startBlock, uint64 startTime) {
        return Guardians.hold(l.g.k, l.g.f, uint64(block.timestamp), DAY);
    }

    /// @notice Notes in the hold history a hold a change of the guardians ended: by a dip of the grace's length, at
    /// the moment the dip reached it; by a replacement's own clear, now. The arguments are the stored moments before
    /// the change.
    function noteHoldEnd(
        Layout storage l,
        uint64 holdBlock,
        uint64 holdTime,
        uint64 dipBlock,
        uint64 dipTime
    )
        internal
    {
        if (holdBlock == 0) return;
        if (l.g.f.holdBlock == holdBlock && l.g.f.holdTime == holdTime) return;
        uint64 now_ = uint64(block.timestamp);
        uint64 end = now_;
        if (dipBlock != 0 && now_ >= dipTime && now_ - dipTime >= DAY) end = dipTime + DAY;
        uint256 n = l.holds.length;
        if (n >= MAX_HOLDS) {
            // the two oldest merge into one spanning both, the earliest start kept
            if (l.holds[1].end > l.holds[0].end) l.holds[0].end = l.holds[1].end;
            for (uint256 i = 1; i + 1 < n; i++) {
                l.holds[i] = l.holds[i + 1];
            }
            l.holds.pop();
        }
        l.holds.push(IGuardians.Hold(holdTime, end));
        emit IIBCAdmin.HoldEnded(holdTime, end);
    }

    /// @notice The stored hold moments, before a change (for `noteHoldEnd`).
    function moments(Layout storage l) internal view returns (uint64, uint64, uint64, uint64) {
        Guardians.Flags storage f = l.g.f;
        return (f.holdBlock, f.holdTime, f.dipBlock, f.dipTime);
    }

    /// @notice Whether the decision `seq` may set `setting`: not when a later decision of the epoch already did. Marks
    /// it as the last when it may.
    function supersede(Layout storage l, bytes32 setting, uint64 seq) internal returns (bool) {
        bytes32 key = keccak256(abi.encode(l.epoch, setting));
        if (l.appliedSeq[key] > seq) return false;
        l.appliedSeq[key] = seq;
        return true;
    }

    /// @notice Freezes the old client id (migrated to `frozen`) and opens the next epoch over the new one: every
    /// unexecuted decision, buffered entry and tombstone of the old epoch is dropped with it (they are keyed by
    /// epoch). Kind 10 and the emergency recovery.
    function replaceRoute(
        Layout storage l,
        address router,
        address frozen,
        string memory oldId,
        string memory newId
    )
        internal
    {
        IICS02ClientMsgs.CounterpartyInfo memory info = IICS02Client(router).getCounterparty(oldId);
        IICS02ClientAccessControlled(router).migrateClient(oldId, info, frozen);
        uint32 e = l.epoch + 1;
        l.epoch = e;
        l.govClient = newId;
        l.lastSeq = 0;
        l.conflictBlock = 0;
        l.lastRecordTime = uint64(block.timestamp);
        emit IIBCAdmin.EpochOpened(e, newId);
    }

    // ---------------------------------------------------------------------------------------- tombstones --

    function isTombstoned(Layout storage l, uint32 epoch, uint64 seq) internal view returns (bool) {
        uint64[2][] storage t = l.tombstones[epoch];
        for (uint256 i = 0; i < t.length; i++) {
            if (t[i][0] <= seq && seq <= t[i][1]) return true;
        }
        return false;
    }

    /// @notice Adds a tombstone range, merging with every stored one it overlaps or touches; with the store full,
    /// merges it with the nearest stored one rather than refuse (the gap's numbers die too).
    function addTombstone(Layout storage l, uint32 epoch, uint64 from, uint64 to) internal {
        uint64[2][] storage t = l.tombstones[epoch];
        uint256 i = 0;
        while (i < t.length) {
            uint64 cf = t[i][0];
            uint64 ct = t[i][1];
            if (cf <= _satInc(to) && from <= _satInc(ct)) {
                if (cf < from) from = cf;
                if (ct > to) to = ct;
                _remove(t, i);
            } else {
                i++;
            }
        }
        if (t.length >= MAX_TOMBSTONES) {
            uint256 best;
            uint64 bestGap = type(uint64).max;
            for (uint256 j = 0; j < t.length; j++) {
                uint64 cf = t[j][0];
                uint64 ct = t[j][1];
                uint64 gap = ct < from ? from - ct : (to < cf ? cf - to : 0);
                if (gap < bestGap) (best, bestGap) = (j, gap);
            }
            if (t[best][0] < from) from = t[best][0];
            if (t[best][1] > to) to = t[best][1];
            _remove(t, best);
        }
        t.push([from, to]);
        emit IIBCAdmin.Tombstoned(epoch, from, to);
    }

    function _remove(uint64[2][] storage t, uint256 i) private {
        uint256 n = t.length;
        for (uint256 k = i; k + 1 < n; k++) {
            t[k] = t[k + 1];
        }
        t.pop();
    }

    function _satInc(uint64 x) private pure returns (uint64) {
        return x == type(uint64).max ? x : x + 1;
    }
}
