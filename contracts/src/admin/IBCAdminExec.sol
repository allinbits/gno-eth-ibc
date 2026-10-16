// SPDX-License-Identifier: LicenseRef-GNO-Network-GPL
pragma solidity ^0.8.28;

// Ported in part from gnolang/bridges (branch ethereum-draft), ethereum/bridge/contracts/src/admin/HlAdminExec.sol:
// the kinds' execution behind a delegatecall, code-hash pins, the fixed gas budget of an upgrade's call, and
// `checkSetup`'s numbered check list. Copyright (C) 2026 NewTendermint, LLC. GNO Network General Public License: see
// contracts/licenses/.

import { IAccessManager } from "@openzeppelin-contracts/access/manager/IAccessManager.sol";
import { IAccessManaged } from "@openzeppelin-contracts/access/manager/IAccessManaged.sol";
import { UUPSUpgradeable } from "@openzeppelin-contracts/proxy/utils/UUPSUpgradeable.sol";
import { UpgradeableBeacon } from "@openzeppelin-contracts/proxy/beacon/UpgradeableBeacon.sol";

import { IICS02Client, IICS02ClientAccessControlled } from "@eureka/interfaces/IICS02Client.sol";
import { IICS26Router } from "@eureka/interfaces/IICS26Router.sol";
import { IICS20Transfer, IICS20TransferAccessControlled } from "@eureka/interfaces/IICS20Transfer.sol";
import { IICS02ClientMsgs } from "@eureka/msgs/IICS02ClientMsgs.sol";
import { IBCRolesLib } from "@eureka/utils/IBCRolesLib.sol";
import { ICS20Lib } from "@eureka/utils/ICS20Lib.sol";

import { IIBCAdmin } from "../interfaces/IIBCAdmin.sol";
import { IGuardians } from "../interfaces/IGuardians.sol";
import { IGnoICS20Controls, IGnoICS20ControlsTypes } from "../interfaces/IGnoICS20Controls.sol";
import { IGnoLightClientStatus } from "../interfaces/IGnoLightClientStatus.sol";
import { Guardians } from "../lib/Guardians.sol";
import { LeakyBucket } from "../lib/LeakyBucket.sol";
import { IBCAdminStorage as S } from "./IBCAdminStorage.sol";
import { FrozenLightClient } from "./FrozenLightClient.sol";
import { IGnoLightClientMsgs } from "../msgs/IGnoLightClientMsgs.sol";

import { IBCAdminSetupCheck } from "./IBCAdminSetupCheck.sol";
import { IBCAdminRecovery } from "./IBCAdminRecovery.sol";

/// @notice What IBCAdminExec asks of a GnoVoucher and of the transfer fork beyond their interfaces.
interface IMulticallLike {
    function multicall(bytes[] calldata data) external returns (bytes[] memory);
}

interface IVoucherLike {
    function ics20() external view returns (address);
}

/// @title IBCAdmin's executor
/// @notice The kinds' logic (at recording and at execution), the emergency recovery and `finishSetup`'s check list.
/// IBCAdmin delegatecalls it at a pinned code hash, so it runs as IBCAdmin, with IBCAdmin's storage (IBCAdminStorage)
/// and authority; called at its own address every function refuses (`NotDelegated`). Kind 9 replaces it by another
/// executor bound to the same router, AccessManager and transfer app.
contract IBCAdminExec is IIBCAdmin {
    /// @notice The gas a kind 7's call is forwarded, whatever gas its executor sends; below CALL_FLOOR left, the
    /// execution reverts (`CallStarved`) and the decision pends.
    uint256 internal constant CALL_GAS = 2_000_000;
    uint256 internal constant CALL_FLOOR = CALL_GAS * 64 / 63 + 10_000;
    /// @notice Gas a step's after-checks get past its call, and the gas a step (`_selfStep`) must have left to start.
    uint256 internal constant AFTER_GAS = 200_000;
    /// @notice Kind 12's budget: an envelope holds at most about nine records, each with a payment (a settlement
    /// never loads or delivers a sender notification: `retryNotification` does).
    uint256 internal constant SETTLE_GAS = 6_000_000;
    /// @notice Most records a kind 12 settles (an envelope holds at most eight): each payment's gas is bounded, so
    /// SETTLE_GAS covers them all.
    uint256 internal constant MAX_SETTLE_ITEMS = 8;
    uint256 internal constant STEP_FLOOR = (CALL_FLOOR + AFTER_GAS + 50_000) * 64 / 63 + 50_000;
    uint64 internal constant MAX_QUARANTINE = 365 days;

    address public immutable router;
    address public immutable accessManager;
    address public immutable ics20;
    /// @notice The light client retired client ids are migrated to.
    address public immutable frozenClient;
    /// @notice `finishSetup`'s check list.
    address public immutable setupCheck;
    /// @notice The emergency recovery's code, which IBCAdmin delegatecalls (pinned with this executor).
    address public immutable recoveryModule;
    address private immutable _self;

    constructor(address router_, address accessManager_, address ics20_) {
        if (router_ == address(0) || accessManager_ == address(0) || ics20_ == address(0)) revert ZeroAddress();
        router = router_;
        accessManager = accessManager_;
        ics20 = ics20_;
        frozenClient = address(new FrozenLightClient());
        setupCheck = address(new IBCAdminSetupCheck());
        recoveryModule = address(new IBCAdminRecovery(router_, ics20_, frozenClient));
        _self = address(this);
    }

    /// @notice What this executor is bound to; IBCAdmin and kind 9 require it to be IBCAdmin's own.
    function bindings() external view returns (address, address, address) {
        return (router, accessManager, ics20);
    }

    modifier delegated() {
        if (address(this) == _self) revert NotDelegated();
        _;
    }

    // ============================================================================================ recording ==

    /// @notice A decision at recording: WAIT (it waits for its delay), DONE_NOW (an immediate kind, executed now) or
    /// SPEND (bad parameters). Every kind's parameters are decoded here; malformed ones revert, which IBCAdmin spends.
    function atRecording(
        uint8 kind,
        uint64 seq,
        bytes calldata p,
        bool suspended
    )
        external
        delegated
        returns (uint8, string memory)
    {
        if (kind == S.KIND_UNPAUSE) {
            (uint8 object, string memory clientId) = abi.decode(p, (uint8, string));
            bool ok = (object == 1 && bytes(clientId).length != 0) || (object == 2 && bytes(clientId).length == 0);
            return ok ? (S.WAIT, "") : (S.SPEND, "params");
        }
        if (kind == S.KIND_SEATS) {
            IGuardians.SeatKey[] memory pairs = abi.decode(p, (IGuardians.SeatKey[]));
            return Guardians.checkReplace(S.layout().g.k, pairs) == bytes4(0) ? (S.WAIT, "") : (S.SPEND, "params");
        }
        if (kind == S.KIND_LIMITS) {
            (string memory clientId, address token, IGnoICS20ControlsTypes.Limits memory l) = _decodeLimits(p);
            if (!_validLimits(token, l)) return (S.SPEND, "params");
            if (_loosens(IGnoICS20Controls(ics20).limits(clientId, token), l)) return (S.WAIT, "");
            if (!S.supersede(S.layout(), _limitsKey(clientId, token), seq)) return (S.SPEND, "superseded");
            IGnoICS20Controls(ics20).setLimits(clientId, token, l);
            return (S.DONE_NOW, "");
        }
        if (kind == S.KIND_VOUCHER) {
            (string memory clientId, string memory baseDenom, address voucher,) =
                abi.decode(p, (string, string, address, bytes32));
            bool ok = bytes(clientId).length != 0 && S.canonicalGnoDenom(baseDenom) && voucher != address(0);
            return ok ? (S.WAIT, "") : (S.SPEND, "params");
        }
        if (kind == S.KIND_CLIENT) {
            (uint8 op, string memory clientId, string memory cp, bytes[] memory prefix, address lc,) =
                abi.decode(p, (uint8, string, string, bytes[], address, bytes32));
            bool ok = (op == 1 || op == 2) && bytes(clientId).length != 0 && lc != address(0)
                && S.canonicalCounterparty(cp, prefix);
            return ok ? (S.WAIT, "") : (S.SPEND, "params");
        }
        if (kind == S.KIND_UPGRADE) {
            (address proxy, address impl,,) = abi.decode(p, (address, address, bytes32, bytes));
            return proxy != address(0) && impl != address(0) ? (S.WAIT, "") : (S.SPEND, "params");
        }
        if (kind == S.KIND_ROLE) {
            (bool grant, uint64 roleId, address account) = abi.decode(p, (bool, uint64, address));
            if (roleId != IBCRolesLib.RELAYER_ROLE || account == address(0)) return (S.SPEND, "role");
            // a revocation waits while an emergency recovery is open (it changes authority), and is due at once after
            if (grant || suspended) return (S.WAIT, "");
            IAccessManager(accessManager).revokeRole(roleId, account);
            return (S.DONE_NOW, "");
        }
        if (kind == S.KIND_HANDOVER) {
            (address x,,) = abi.decode(p, (address, bytes32, bytes));
            return x != address(0) ? (S.WAIT, "") : (S.SPEND, "params");
        }
        if (kind == S.KIND_ROUTE) {
            (string memory oldId, string memory newId,) = abi.decode(p, (string, string, uint64));
            bool ok = bytes(oldId).length != 0 && bytes(newId).length != 0
                && keccak256(bytes(oldId)) != keccak256(bytes(newId));
            return ok ? (S.WAIT, "") : (S.SPEND, "params");
        }
        if (kind == S.KIND_SETTLE) {
            (string memory sid, IGnoICS20ControlsTypes.SettleItem[] memory items) =
                abi.decode(p, (string, IGnoICS20ControlsTypes.SettleItem[]));
            bool ok = bytes(sid).length != 0 && items.length != 0 && items.length <= MAX_SETTLE_ITEMS;
            for (uint256 i = 0; ok && i < items.length; i++) {
                ok = items[i].action >= 1 && items[i].action <= 5;
            }
            return ok ? (S.WAIT, "") : (S.SPEND, "params");
        }
        if (kind == S.KIND_REOPEN) {
            string memory rid = abi.decode(p, (string));
            return bytes(rid).length != 0 ? (S.WAIT, "") : (S.SPEND, "params");
        }
        // KIND_SETTINGS (IBCAdmin records no other kind here)
        (string memory id, uint64 q) = abi.decode(p, (string, uint64));
        if (q > MAX_QUARANTINE || bytes(id).length == 0) return (S.SPEND, "params");
        if (q < IGnoICS20Controls(ics20).quarantineSeconds(id)) return (S.WAIT, "");
        if (!S.supersede(S.layout(), _quarantineKey(id), seq)) return (S.SPEND, "superseded");
        IGnoICS20Controls(ics20).setQuarantine(id, q);
        return (S.DONE_NOW, "");
    }

    function _decodeLimits(bytes calldata p)
        private
        pure
        returns (string memory clientId, address token, IGnoICS20ControlsTypes.Limits memory l)
    {
        (clientId, token, l.maxPerMessage, l.dayCap, l.refundCap, l.sendMax, l.sendMin) =
            abi.decode(p, (string, address, uint256, uint256, uint256, uint256, uint256));
    }

    /// @notice The settings `supersede` orders, keyed by route key (so every client id of a route shares them).
    function _limitsKey(string memory clientId, address token) private view returns (bytes32) {
        return keccak256(abi.encode("limits", IGnoICS20Controls(ics20).routeKey(clientId), token));
    }

    function _quarantineKey(string memory clientId) private view returns (bytes32) {
        return keccak256(abi.encode("quarantine", IGnoICS20Controls(ics20).routeKey(clientId)));
    }

    function _validLimits(address token, IGnoICS20ControlsTypes.Limits memory l) private pure returns (bool) {
        return token != address(0) && l.dayCap <= LeakyBucket.MAX_CAP && l.refundCap <= LeakyBucket.MAX_CAP
            && (l.sendMax == 0 || l.sendMin <= l.sendMax);
    }

    /// @notice Whether new limits loosen any field: a first setting always does (unset limits refuse everything);
    /// raising the receive maximum, the day cap, the refund cap or the send maximum (0 = none, the loosest), or
    /// lowering the send minimum.
    function _loosens(
        IGnoICS20ControlsTypes.LimitsView memory cur,
        IGnoICS20ControlsTypes.Limits memory n
    )
        private
        pure
        returns (bool)
    {
        if (!cur.set) return true;
        IGnoICS20ControlsTypes.Limits memory c = cur.limits;
        bool sendMaxLoosens = c.sendMax != 0 && (n.sendMax == 0 || n.sendMax > c.sendMax);
        return n.maxPerMessage > c.maxPerMessage || n.dayCap > c.dayCap || n.refundCap > c.refundCap || sendMaxLoosens
            || n.sendMin < c.sendMin;
    }

    // ============================================================================================ execution ==

    /// @notice Carries out a matured decision IBCAdmin's `execute` closed; the reason it is spent, or "" when it
    /// executed. A call that reverts reverts `execute` whole, and the decision stays pending for a retry.
    function run(
        uint8 kind,
        uint64 seq,
        bytes calldata p,
        uint64 recordedBlock
    )
        external
        delegated
        returns (string memory)
    {
        if (kind == S.KIND_UNPAUSE) return _unpause(p, recordedBlock);
        if (kind == S.KIND_SEATS) return _seats(p);
        if (kind == S.KIND_LIMITS) {
            (string memory clientId, address token, IGnoICS20ControlsTypes.Limits memory l) = _decodeLimits(p);
            if (!_validLimits(token, l)) return "params";
            // a tightening recorded after this loosening, and applied at once, stands
            if (!S.supersede(S.layout(), _limitsKey(clientId, token), seq)) return "superseded";
            IGnoICS20Controls(ics20).setLimits(clientId, token, l);
            return "";
        }
        if (kind == S.KIND_VOUCHER) return _voucher(p);
        if (kind == S.KIND_CLIENT) return _client(p);
        if (kind == S.KIND_UPGRADE) return _upgrade(p);
        if (kind == S.KIND_ROLE) {
            (bool grant, uint64 roleId, address account) = abi.decode(p, (bool, uint64, address));
            if (roleId != IBCRolesLib.RELAYER_ROLE || account == address(0)) return "role";
            // a grant after its 7 days; a revocation an open recovery held back
            if (grant) IAccessManager(accessManager).grantRole(roleId, account, 0);
            else IAccessManager(accessManager).revokeRole(roleId, account);
            return "";
        }
        if (kind == S.KIND_HANDOVER) return _handover(p);
        if (kind == S.KIND_ROUTE) return _route(p);
        if (kind == S.KIND_SETTLE) {
            (string memory sid, IGnoICS20ControlsTypes.SettleItem[] memory items) =
                abi.decode(p, (string, IGnoICS20ControlsTypes.SettleItem[]));
            return
                _callWith(ics20, abi.encodeCall(IGnoICS20Controls.settleRecords, (sid, items)), SETTLE_GAS)
                    ? ""
                    : "settle";
        }
        if (kind == S.KIND_REOPEN) {
            string memory rid = abi.decode(p, (string));
            return _call(ics20, abi.encodeCall(IGnoICS20Controls.reopenRoute, (rid))) ? "" : "route";
        }
        // KIND_SETTINGS: a shortening (a lengthening executed at recording)
        (string memory id, uint64 q) = abi.decode(p, (string, uint64));
        if (q > MAX_QUARANTINE) return "params";
        if (!S.supersede(S.layout(), _quarantineKey(id), seq)) return "superseded";
        IGnoICS20Controls(ics20).setQuarantine(id, q);
        return "";
    }

    /// @notice Kind 2: object 1 the transfer route of `clientId`, 2 IBCAdmin; spent under a hold on that object;
    /// clears the flags (and on a route its refunds flags) set at a block before the decision's recording, and on
    /// IBCAdmin a conflict's flag raised before it.
    function _unpause(bytes calldata p, uint64 recordedBlock) private returns (string memory) {
        (uint8 object, string memory clientId) = abi.decode(p, (uint8, string));
        if (object == 1) {
            if (
                IGnoICS20Controls(ics20).routeHold(clientId).blockNumber != 0
                    || IGnoICS20Controls(ics20).refundsHold(clientId).blockNumber != 0
            ) return "hold";
            IGnoICS20Controls(ics20).unpauseRoute(clientId, recordedBlock);
            return "";
        }
        S.Layout storage l = S.layout();
        (bool stands,,) = S.hold(l);
        if (stands) return "hold";
        (uint64 hb, uint64 ht, uint64 db, uint64 dt) = S.moments(l);
        uint256 n = Guardians.unpause(l.g.k, l.g.f, recordedBlock, uint64(block.number), uint64(block.timestamp), S.DAY);
        S.noteHoldEnd(l, hb, ht, db, dt);
        if (l.conflictBlock != 0 && l.conflictBlock < recordedBlock) l.conflictBlock = 0;
        emit Unpaused(recordedBlock, n);
        return "";
    }

    /// @notice Kind 3: spent when it names a key that holds any seat now or the replacement's rules refuse it; the
    /// transfer app's copy of the keys follows.
    function _seats(bytes calldata p) private returns (string memory) {
        IGuardians.SeatKey[] memory pairs = abi.decode(p, (IGuardians.SeatKey[]));
        S.Layout storage l = S.layout();
        for (uint256 i = 0; i < pairs.length; i++) {
            if (Guardians.position(l.g.k, pairs[i].key) != Guardians.KEYS) return "current key";
        }
        if (Guardians.checkReplace(l.g.k, pairs) != bytes4(0)) return "params";
        (uint64 hb, uint64 ht, uint64 db, uint64 dt) = S.moments(l);
        Guardians.replace(l.g, pairs, uint64(block.number), uint64(block.timestamp), S.DAY);
        S.noteHoldEnd(l, hb, ht, db, dt);
        IGnoICS20Controls(ics20).setGuardianKeys(l.g.k.keys);
        S.Recovery storage r = l.recovery;
        for (uint256 i = 0; i < pairs.length; i++) {
            uint8 seat = pairs[i].seat;
            // a new key never inherits the replaced key's recovery approval or cancel vote
            if (seat < Guardians.SEATS) {
                r.approved[seat] = bytes32(0);
                r.cancels &= ~uint8(1 << seat);
            }
            emit GuardiansSet(seat, pairs[i].key);
        }
        return "";
    }

    /// @notice Kind 5: registers `transfer/<clientId>/<baseDenom>`'s voucher, whose code is the decision's and which
    /// answers to the transfer app; spent if the denom or the token is already registered.
    function _voucher(bytes calldata p) private returns (string memory) {
        (string memory clientId, string memory baseDenom, address voucher, bytes32 codeHash) =
            abi.decode(p, (string, string, address, bytes32));
        if (!_codeIs(voucher, codeHash)) return "codehash";
        if (!S.canonicalGnoDenom(baseDenom)) return "denom";
        (bool ok, bytes memory ret) = voucher.staticcall(abi.encodeCall(IVoucherLike.ics20, ()));
        if (!ok || ret.length != 32 || abi.decode(ret, (address)) != ics20) return "voucher";
        string memory denom = string.concat(ICS20Lib.DEFAULT_PORT_ID, "/", clientId, "/", baseDenom);
        if (!_call(ics20, abi.encodeCall(IICS20TransferAccessControlled.setCustomERC20, (denom, voucher)))) {
            return "exists";
        }
        return "";
    }

    /// @notice Kind 6: op 1 adds `clientId` (a custom id), op 2 migrates it to `lightClient`, whose code is the
    /// decision's; spent if the router refuses it.
    function _client(bytes calldata p) private returns (string memory) {
        (
            uint8 op,
            string memory clientId,
            string memory counterpartyClientId,
            bytes[] memory merklePrefix,
            address lc,
            bytes32 codeHash
        ) = abi.decode(p, (uint8, string, string, bytes[], address, bytes32));
        if (!_codeIs(lc, codeHash)) return "codehash";
        // gno.land's exact prefix; a verifier swap keeps the client's counterparty
        if (!S.canonicalCounterparty(counterpartyClientId, merklePrefix)) return "counterparty";
        if (
            op == 2
                && keccak256(bytes(IICS02Client(router).getCounterparty(clientId).clientId))
                    != keccak256(bytes(counterpartyClientId))
        ) {
            return "counterparty";
        }
        // a retired client id is final: never migrated back to a live client (ADR §7.12)
        if (op == 2 && IGnoICS20Controls(ics20).isRetired(clientId)) return "retired";
        IICS02ClientMsgs.CounterpartyInfo memory info =
            IICS02ClientMsgs.CounterpartyInfo(counterpartyClientId, merklePrefix);
        bytes memory call = op == 1
            ? abi.encodeCall(IICS02ClientAccessControlled.addClient, (clientId, info, lc))
            : abi.encodeCall(IICS02ClientAccessControlled.migrateClient, (clientId, info, lc));
        // a verifier swap never drops the route's running quarantine (ADR §7.10)
        if (op == 2) IGnoICS20Controls(ics20).checkpointQuarantine(clientId);
        if (!_call(router, call)) return "client";
        if (address(IICS02Client(router).getClient(clientId)) != lc) revert AuthorityLost(router);
        // a client a governed decision added: the only kind a route replacement may move to
        if (op == 1) S.layout().enrolled[keccak256(bytes(clientId))] = true;
        return "";
    }

    /// @notice Kind 7: the router or the transfer app (UUPS `upgradeToAndCall`, the call given CALL_GAS exactly),
    /// or one of the transfer app's beacons (escrow, IBCERC20; no call); the implementation's code the decision's.
    /// The migration call runs in the new code with IBCAdmin's authority, so it is empty or its selector is on this
    /// executor's pinned allow-list (`migrationAllowed`, empty here: only a kind 9 hand-over to other code extends
    /// it); never an upgrade or a client change, which kinds 6 and 7 validate themselves. The upgrade and its
    /// after-checks run as a self-step (`applyUpgrade`): a failure rolls them back and spends the decision.
    function _upgrade(bytes calldata p) private returns (string memory) {
        (address proxy, address impl, bytes32 codeHash, bytes memory call) =
            abi.decode(p, (address, address, bytes32, bytes));
        if (!_codeIs(impl, codeHash)) return "codehash";
        bool uups = proxy == router || proxy == ics20;
        if (!uups) {
            bool escrow = proxy == IICS20Transfer(ics20).getEscrowBeacon();
            if (!escrow && proxy != IICS20Transfer(ics20).getIBCERC20Beacon()) return "params";
            if (call.length != 0) return "params";
        } else if (call.length != 0) {
            if (call.length < 4 || !migrationAllowed(proxy, bytes4(call))) return "migration call";
            // a floor no allow-list lifts: the call never sets other code (no decision pinned it)
            bytes4 sel = bytes4(call);
            if (
                sel == UUPSUpgradeable.upgradeToAndCall.selector || sel == IMulticallLike.multicall.selector
                    || sel == IICS20TransferAccessControlled.upgradeEscrowTo.selector
                    || sel == IICS20TransferAccessControlled.upgradeIBCERC20To.selector
            ) {
                return "nested upgrade";
            }
        }
        return _selfStep(abi.encodeCall(IBCAdminExec.applyUpgrade, (proxy, impl, call))) ? "" : "upgrade";
    }

    /// @notice Kind 7's allow-list of migration calls: a selector a migration call to `proxy`'s new code may have.
    /// Pinned in this code (empty: every kind 7 migration call is refused); an executor installed by kind 9 may
    /// carry its own.
    function migrationAllowed(address, bytes4) public pure virtual returns (bool) {
        return false;
    }

    /// @notice Kind 7's effect and after-checks, in a frame of its own (`_selfStep`): any failure rolls it back
    /// whole and spends the decision. The proxy still answers to the AccessManager and keeps its bindings; a beacon
    /// points at the implementation and is still the transfer app's.
    function applyUpgrade(address proxy, address impl, bytes calldata call) external delegated {
        _selfOnly();
        // the beacons this decision does not upgrade keep their code (whatever the new code's call does)
        address escrowBeacon = IICS20Transfer(ics20).getEscrowBeacon();
        address tokenBeacon = IICS20Transfer(ics20).getIBCERC20Beacon();
        address escrowImpl = UpgradeableBeacon(escrowBeacon).implementation();
        address tokenImpl = UpgradeableBeacon(tokenBeacon).implementation();
        if (proxy == router || proxy == ics20) {
            // the transfer app keeps the controls: the new code answers the pinned probe with at least the running
            // version, before the upgrade (the implementation) and after it (the proxy)
            uint256 running = proxy == ics20 ? _version(ics20, "gnoControlsVersion()") : 0;
            uint256 v = proxy == ics20 ? _modulesVersion(impl) : 0;
            if (v < running) revert AuthorityLost(proxy);
            UUPSUpgradeable(proxy).upgradeToAndCall{ gas: CALL_GAS }(impl, call);
            // through the proxy: the fork, its controls and its reconciliation module all answer, at that version
            if (
                proxy == ics20
                    && (_version(ics20, "gnoControlsVersion()") != v
                        || _version(ics20, "gnoControlsModuleVersion()") != v
                        || _version(ics20, "gnoReconcileModuleVersion()") != v)
            ) revert AuthorityLost(proxy);
            if (IAccessManaged(proxy).authority() != accessManager) revert AuthorityLost(proxy);
            if (proxy == ics20) {
                if (IICS20Transfer(ics20).ics26() != router) revert AuthorityLost(proxy);
            } else if (
                address(IICS26Router(router).getIBCApp(PORT)) != address(this)
                    || address(IICS26Router(router).getIBCApp(ICS20Lib.DEFAULT_PORT_ID)) != ics20
            ) {
                revert AuthorityLost(proxy);
            }
        } else if (proxy == escrowBeacon) {
            IICS20TransferAccessControlled(ics20).upgradeEscrowTo(impl);
            escrowImpl = impl;
        } else {
            IICS20TransferAccessControlled(ics20).upgradeIBCERC20To(impl);
            tokenImpl = impl;
        }
        if (
            UpgradeableBeacon(escrowBeacon).implementation() != escrowImpl
                || UpgradeableBeacon(tokenBeacon).implementation() != tokenImpl
                || UpgradeableBeacon(escrowBeacon).owner() != ics20 || UpgradeableBeacon(tokenBeacon).owner() != ics20
        ) {
            revert AuthorityLost(proxy);
        }
    }

    /// @notice A version probe of `target`, zero if it does not answer one.
    function _version(address target, string memory probe) private view returns (uint256) {
        (bool ok, bytes memory ret) = target.staticcall(abi.encodeWithSignature(probe));
        return ok && ret.length == 32 ? abi.decode(ret, (uint256)) : 0;
    }

    /// @notice A fork implementation's controls version, if its modules (controls, then reconciliation) are code
    /// answering the same version; zero otherwise.
    function _modulesVersion(address impl) private view returns (uint256 v) {
        v = _version(impl, "gnoControlsVersion()");
        (bool ok, bytes memory ret) = impl.staticcall(abi.encodeWithSignature("CONTROLS()"));
        address controls = ok && ret.length == 32 ? abi.decode(ret, (address)) : address(0);
        if (!_isCode(controls) || _version(controls, "gnoControlsModuleVersion()") != v) return 0;
        (ok, ret) = controls.staticcall(abi.encodeWithSignature("RECONCILE()"));
        address reconcile = ok && ret.length == 32 ? abi.decode(ret, (address)) : address(0);
        if (!_isCode(reconcile) || _version(reconcile, "gnoReconcileModuleVersion()") != v) return 0;
    }

    /// @notice Runs a step of this executor as IBCAdmin in a call frame of its own (IBCAdmin.selfDelegate), so that
    /// its failure rolls it back and spends the decision. Below STEP_FLOOR gas, or if the step itself finds less than
    /// its budget (`CallStarved`), the execution reverts and the decision pends, so nobody spends one by starving it.
    function _selfStep(bytes memory step) private returns (bool ok) {
        if (gasleft() < STEP_FLOOR) revert CallStarved();
        bytes memory ret;
        (ok, ret) = address(this).call(abi.encodeWithSignature("selfDelegate(bytes)", step));
        if (!ok && ret.length >= 4 && bytes4(ret) == CallStarved.selector) revert CallStarved();
    }

    /// @notice A step reached only through `_selfStep` (IBCAdmin.selfDelegate is the caller), with its gas.
    function _selfOnly() private view {
        if (msg.sender != address(this)) revert NotSelf();
        if (gasleft() < CALL_FLOOR + AFTER_GAS) revert CallStarved();
    }

    /// @notice IBCAdmin's port on the router (IBCAdmin.PORT).
    string internal constant PORT = "ibcgov";

    /// @notice Kind 9: the executor's code is the decision's and it is bound as this one; the code hash pin moves to
    /// it atomically, then the optional one-time migration call runs in it, both as a self-step (`applyHandover`): a
    /// failure rolls them back and spends the decision. No state or authority moves: both stay in IBCAdmin.
    function _handover(bytes calldata p) private returns (string memory) {
        (address x, bytes32 codeHash, bytes memory migration) = abi.decode(p, (address, bytes32, bytes));
        if (!_codeIs(x, codeHash)) return "codehash";
        (bool ok, bytes memory ret) = x.staticcall(abi.encodeCall(IBCAdminExec.bindings, ()));
        if (!ok || ret.length != 96) return "bindings";
        (address r, address am, address t) = abi.decode(ret, (address, address, address));
        if (r != router || am != accessManager || t != ics20) return "bindings";
        return _selfStep(abi.encodeCall(IBCAdminExec.applyHandover, (x, codeHash, migration))) ? "" : "migration";
    }

    /// @notice Kind 9's effect, in a frame of its own: the pin moves, then the migration call runs in the new
    /// executor (CALL_GAS); its failure rolls the swap back and spends the decision.
    function applyHandover(address x, bytes32 codeHash, bytes calldata migration) external delegated {
        _selfOnly();
        S.Layout storage l = S.layout();
        l.exec = x;
        l.execHash = codeHash;
        emit ExecReplaced(x, codeHash);
        if (migration.length != 0) {
            (bool ok, bytes memory ret) = x.delegatecall{ gas: CALL_GAS }(migration);
            if (!ok) {
                // solhint-disable-next-line no-inline-assembly
                assembly ("memory-safe") {
                    revert(add(ret, 32), mload(ret))
                }
            }
        }
    }

    /// @notice Kind 10 `(oldClientId, newClientId, suspectFrom)`: `oldClientId` must be this epoch's client and
    /// `newClientId` a custom id a kind 6 enrolled; `suspectFrom` starts the suspected compromise interval; retires and
    /// freezes the old id, migrates the route, and opens the next epoch over the new id.
    function _route(bytes calldata p) private returns (string memory) {
        (string memory oldId, string memory newId, uint64 suspectFrom) = abi.decode(p, (string, string, uint64));
        S.Layout storage l = S.layout();
        if (keccak256(bytes(oldId)) != keccak256(bytes(l.govClient))) return "client";
        // only a custom id a kind 6 enrolled (its verifier code-hash pinned), never one the router generated
        if (!l.enrolled[keccak256(bytes(newId))]) return "client";
        IGnoICS20Controls(ics20).checkpointQuarantine(oldId);
        if (!_call(ics20, abi.encodeCall(IGnoICS20Controls.migrateRoute, (oldId, newId, suspectFrom)))) return "route";
        S.replaceRoute(l, router, frozenClient, oldId, newId);
        return "";
    }

    // ================================================================================================ setup ==

    /// @notice `finishSetup`'s self-check (IBCAdminSetupCheck's numbered check list), run against IBCAdmin.
    function checkSetup(address deployer) external view delegated {
        IBCAdminSetupCheck(setupCheck).check(address(this), deployer);
    }

    // ================================================================================================ helpers ==

    /// @notice A call whose failure is an answer, not an error (the decision is spent): made with a fixed gas budget,
    /// and only with enough gas left for all of it (`CallStarved` otherwise: the decision pends), so nobody can make it
    /// fail by starving it. A remaining-gas test after the call could not tell: the proxies on the way each keep a
    /// 64th and hand it back.
    function _call(address target, bytes memory data) private returns (bool ok) {
        return _callWith(target, data, S.RECORD_GAS);
    }

    function _callWith(address target, bytes memory data, uint256 budget) private returns (bool ok) {
        if (gasleft() < budget * 64 / 63 + 10_000) revert CallStarved();
        (ok,) = target.call{ gas: budget }(data);
    }

    /// @notice Whether `target`'s code is the one the decision pins (false spends it: no code, an EIP-7702 delegation
    /// designator or another code hash; ADR §5.4: a decision that fails its checks at execution is never retried).
    function _codeIs(address target, bytes32 codeHash) private view returns (bool) {
        return _isCode(target) && target.codehash == codeHash;
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
