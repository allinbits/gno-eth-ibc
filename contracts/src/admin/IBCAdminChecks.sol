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
    /// `chainId` that is not frozen, and neither frozen nor expired by its status views.
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
        return !_ask(lc, IGnoLightClientStatus.isFrozen.selector) && !_ask(lc, IGnoLightClientStatus.isExpired.selector);
    }

    function _ask(address lc, bytes4 selector) private view returns (bool) {
        (bool ok, bytes memory ret) = lc.staticcall(abi.encodeWithSelector(selector));
        return ok && ret.length == 32 && abi.decode(ret, (bool));
    }
}
