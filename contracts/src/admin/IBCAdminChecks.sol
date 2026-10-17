// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IGuardians } from "../interfaces/IGuardians.sol";
import { IGnoICS20ControlsTypes } from "../interfaces/IGnoICS20Controls.sol";
import { IGnoLightClientStatus } from "../interfaces/IGnoLightClientStatus.sol";
import { IGnoLightClientMsgs } from "../msgs/IGnoLightClientMsgs.sol";
import { IBCAdminStorage as S } from "./IBCAdminStorage.sol";

/// @title IBCAdmin's stateless checks
/// @notice Called by the executor (a view contract it deploys, so pinned with it; EIP-170 keeps them apart): the
/// canonical form of every kind's parameters, gno.land's denoms and counterparties, and whether a light client may
/// verify for gno.land (its code, its chain id, neither frozen nor expired).
contract IBCAdminChecks {
    /// @notice Whether `p` is exactly the canonical `abi.encode` of the kind's tuple (no trailing data, no
    /// non-canonical offset or padding): decoded, re-encoded and compared. Malformed bytes revert (spent too).
    function canonicalParams(uint8 kind, bytes calldata p) external pure returns (bool) {
        bytes memory e;
        if (kind == S.KIND_UNPAUSE) {
            (uint8 a, string memory b) = abi.decode(p, (uint8, string));
            e = abi.encode(a, b);
        } else if (kind == S.KIND_SEATS) {
            e = abi.encode(abi.decode(p, (IGuardians.SeatKey[])));
        } else if (kind == S.KIND_LIMITS) {
            (string memory a, address b, uint256 c, uint256 d, uint256 f, uint256 g, uint256 h) =
                abi.decode(p, (string, address, uint256, uint256, uint256, uint256, uint256));
            e = abi.encode(a, b, c, d, f, g, h);
        } else if (kind == S.KIND_VOUCHER) {
            (string memory a, string memory b, address c, bytes32 d) = abi.decode(p, (string, string, address, bytes32));
            e = abi.encode(a, b, c, d);
        } else if (kind == S.KIND_CLIENT) {
            (uint8 a, string memory b, string memory c, bytes[] memory d, address f, bytes32 g) =
                abi.decode(p, (uint8, string, string, bytes[], address, bytes32));
            e = abi.encode(a, b, c, d, f, g);
        } else if (kind == S.KIND_UPGRADE) {
            (address a, address b, bytes32 c, bytes memory d) = abi.decode(p, (address, address, bytes32, bytes));
            e = abi.encode(a, b, c, d);
        } else if (kind == S.KIND_ROLE) {
            (bool a, uint64 b, address c) = abi.decode(p, (bool, uint64, address));
            e = abi.encode(a, b, c);
        } else if (kind == S.KIND_HANDOVER) {
            (address a, bytes32 b, bytes memory c) = abi.decode(p, (address, bytes32, bytes));
            e = abi.encode(a, b, c);
        } else if (kind == S.KIND_ROUTE) {
            (string memory a, string memory b, uint64 c) = abi.decode(p, (string, string, uint64));
            e = abi.encode(a, b, c);
        } else if (kind == S.KIND_SETTINGS) {
            (string memory a, uint64 b) = abi.decode(p, (string, uint64));
            e = abi.encode(a, b);
        } else if (kind == S.KIND_SETTLE) {
            (string memory a, IGnoICS20ControlsTypes.SettleItem[] memory b) =
                abi.decode(p, (string, IGnoICS20ControlsTypes.SettleItem[]));
            e = abi.encode(a, b);
        } else if (kind == S.KIND_REOPEN) {
            e = abi.encode(abi.decode(p, (string)));
        } else {
            return false;
        }
        return keccak256(e) == keccak256(p);
    }

    /// @notice See IBCAdminStorage.canonicalGnoDenom.
    function canonicalGnoDenom(string calldata denom) external pure returns (bool) {
        return S.canonicalGnoDenom(denom);
    }

    /// @notice See IBCAdminStorage.canonicalCounterparty.
    function canonicalCounterparty(string calldata clientId, bytes[] calldata prefix) external pure returns (bool) {
        return S.canonicalCounterparty(clientId, prefix);
    }

    /// @notice Whether `lc` may verify for gno.land: contract code (not an EIP-7702 designator), a client state of
    /// `chainId` that is not frozen, and its status views answering exactly (fail closed: a view that is missing,
    /// reverts or returns anything but its exact encoding makes the client unusable): not frozen, not expired, and a
    /// last transition.
    function usableClient(address lc, string calldata chainId) external view returns (bool) {
        uint256 size;
        bytes32 head;
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            size := extcodesize(lc)
            let ptr := mload(0x40)
            mstore(ptr, 0)
            extcodecopy(lc, ptr, 0, 3)
            head := mload(ptr)
        }
        if (size == 0 || bytes3(head) == 0xef0100) return false;
        (bool ok, bytes memory ret) = lc.staticcall(abi.encodeWithSignature("getClientState()"));
        if (!ok) return false;
        IGnoLightClientMsgs.ClientState memory cs =
            abi.decode(abi.decode(ret, (bytes)), (IGnoLightClientMsgs.ClientState));
        if (keccak256(bytes(cs.chainId)) != keccak256(bytes(chainId)) || cs.isFrozen) return false;
        (bool okF, bool frozen) = flag(lc, IGnoLightClientStatus.isFrozen.selector);
        (bool okE, bool expired) = flag(lc, IGnoLightClientStatus.isExpired.selector);
        return okF && okE && !frozen && !expired && transitionKnown(lc);
    }

    /// @notice A boolean status view, strictly: answered only by a successful call returning exactly one word that
    /// is 0 or 1.
    function flag(address lc, bytes4 selector) public view returns (bool answered, bool value) {
        (bool ok, bytes memory ret) = lc.staticcall(abi.encodeWithSelector(selector));
        if (!ok || ret.length != 32) return (false, false);
        uint256 w = abi.decode(ret, (uint256));
        if (w > 1) return (false, false);
        return (true, w == 1);
    }

    /// @notice Whether `lastTransition()` answers exactly: two words, each a uint64.
    function transitionKnown(address lc) public view returns (bool) {
        (bool ok, bytes memory ret) =
            lc.staticcall(abi.encodeWithSelector(IGnoLightClientStatus.lastTransition.selector));
        if (!ok || ret.length != 64) return false;
        (uint256 a, uint256 b) = abi.decode(ret, (uint256, uint256));
        return a <= type(uint64).max && b <= type(uint64).max;
    }

    // ------------------------------------------------------------------------------- transfer-app modules --

    /// @notice A version probe of `target`, zero if it does not answer exactly one word.
    function version(address target, string calldata probe) public view returns (uint256) {
        (bool ok, bytes memory ret) = target.staticcall(abi.encodeWithSignature(probe));
        return ok && ret.length == 32 ? abi.decode(ret, (uint256)) : 0;
    }

    function _word(address target, string memory probe) private view returns (bytes32) {
        (bool ok, bytes memory ret) = target.staticcall(abi.encodeWithSignature(probe));
        return ok && ret.length == 32 ? abi.decode(ret, (bytes32)) : bytes32(0);
    }

    function _module(address holder, string memory probe) private view returns (address) {
        (bool ok, bytes memory ret) = holder.staticcall(abi.encodeWithSignature(probe));
        return ok && ret.length == 32 ? abi.decode(ret, (address)) : address(0);
    }

    function _code(address a) private view returns (bool) {
        return a.code.length != 0;
    }

    /// @notice A fork implementation's controls version, if its delegate graph is whole: the controls, the
    /// reconciliation and the evidence modules are code answering that version, each recording its own address as
    /// its own (`gnoSelf`) and with the code hash its holder recorded at construction (so the implementation's pinned
    /// hash fixes them all); zero otherwise.
    function modulesVersion(address impl) external view returns (uint256 v) {
        v = this.version(impl, "gnoControlsVersion()");
        address controls = _module(impl, "CONTROLS()");
        if (!_code(controls) || this.version(controls, "gnoControlsModuleVersion()") != v) return 0;
        if (_module(controls, "gnoSelf()") != controls) return 0;
        if (controls.codehash != _word(impl, "CONTROLS_HASH()")) return 0;
        address reconcile = _module(controls, "RECONCILE()");
        if (!_code(reconcile) || this.version(reconcile, "gnoReconcileModuleVersion()") != v) return 0;
        if (_module(reconcile, "gnoSelf()") != reconcile) return 0;
        if (reconcile.codehash != _word(controls, "RECONCILE_HASH()")) return 0;
        address evidence = _module(reconcile, "EVIDENCE()");
        if (!_code(evidence) || this.version(evidence, "gnoEvidenceModuleVersion()") != v) return 0;
        if (_module(evidence, "gnoSelf()") != evidence) return 0;
        if (evidence.codehash != _word(reconcile, "EVIDENCE_HASH()")) return 0;
    }

    /// @notice Whether the transfer proxy, its controls, reconciliation and evidence modules all answer version `v`
    /// through the proxy (the last three by delegation).
    function proxyAnswers(address proxy, uint256 v) external view returns (bool) {
        return this.version(proxy, "gnoControlsVersion()") == v
            && this.version(proxy, "gnoControlsModuleVersion()") == v
            && this.version(proxy, "gnoReconcileModuleVersion()") == v
            && this.version(proxy, "gnoEvidenceModuleVersion()") == v;
    }
}
