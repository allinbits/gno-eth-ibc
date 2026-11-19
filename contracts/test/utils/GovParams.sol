// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IGuardians } from "../../src/interfaces/IGuardians.sol";

/// @notice The `params` of each governance decision kind (ADR pr6375 §5.4 table): the Solidity ABI encoding of the
/// kind's tuple, as `abi.encode(field1, field2, ...)` (no outer offset), which IBCAdminExec decodes with
/// `abi.decode(params, (T1, T2, ...))`.
library GovParams {
    struct Range {
        uint64 from;
        uint64 to;
    }

    function cancel(Range[] memory ranges) internal pure returns (bytes memory) {
        return abi.encode(ranges);
    }

    function cancel1(uint64 from, uint64 to) internal pure returns (bytes memory) {
        Range[] memory r = new Range[](1);
        r[0] = Range(from, to);
        return abi.encode(r);
    }

    function unpause(uint8 object, string memory clientId) internal pure returns (bytes memory) {
        return abi.encode(object, clientId);
    }

    function seats(IGuardians.SeatKey[] memory pairs) internal pure returns (bytes memory) {
        return abi.encode(pairs);
    }

    function seat1(uint8 seat, address key) internal pure returns (bytes memory) {
        IGuardians.SeatKey[] memory p = new IGuardians.SeatKey[](1);
        p[0] = IGuardians.SeatKey(seat, key);
        return abi.encode(p);
    }

    function limits(
        string memory clientId,
        address token,
        uint256 maxPerMessage,
        uint256 dayCap,
        uint256 refundCap,
        uint256 sendMax,
        uint256 sendMin
    )
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(clientId, token, maxPerMessage, dayCap, refundCap, sendMax, sendMin);
    }

    function voucher(
        string memory clientId,
        string memory baseDenom,
        address token,
        bytes32 codeHash
    )
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(clientId, baseDenom, token, codeHash);
    }

    function client(
        uint8 op,
        string memory clientId,
        string memory counterpartyClientId,
        bytes[] memory merklePrefix,
        address lightClient,
        bytes32 codeHash
    )
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(op, clientId, counterpartyClientId, merklePrefix, lightClient, codeHash);
    }

    function upgrade(
        address proxy,
        address implementation,
        bytes32 codeHash,
        bytes memory call
    )
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(proxy, implementation, codeHash, call);
    }

    function role(bool grant, uint64 roleId, address account) internal pure returns (bytes memory) {
        return abi.encode(grant, roleId, account);
    }

    function handover(address exec, bytes32 codeHash, bytes memory migrationCall) internal pure returns (bytes memory) {
        return abi.encode(exec, codeHash, migrationCall);
    }

    function route(
        string memory oldClientId,
        string memory newClientId,
        uint64 suspectFrom
    )
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(oldClientId, newClientId, suspectFrom);
    }

    /// @notice A replacement with no suspected compromise interval (nothing processed through the old client is
    /// suspect).
    function route(string memory oldClientId, string memory newClientId) internal pure returns (bytes memory) {
        return route(oldClientId, newClientId, type(uint64).max);
    }

    function settings(string memory clientId, uint64 quarantineSeconds) internal pure returns (bytes memory) {
        return abi.encode(clientId, quarantineSeconds);
    }

    struct SettleItem {
        uint64 sequence;
        uint8 action;
        uint256 amount;
    }

    function settle(string memory clientId, SettleItem[] memory items) internal pure returns (bytes memory) {
        return abi.encode(clientId, items);
    }

    function settle1(
        string memory clientId,
        uint64 sequence,
        uint8 action,
        uint256 amount
    )
        internal
        pure
        returns (bytes memory)
    {
        SettleItem[] memory items = new SettleItem[](1);
        items[0] = SettleItem(sequence, action, amount);
        return abi.encode(clientId, items);
    }

    function reopen(string memory clientId) internal pure returns (bytes memory) {
        return abi.encode(clientId);
    }

    /// @notice Kind 14 `(string clientId)`: the current epoch's client of gno.land.
    function disableRecovery(string memory clientId) internal pure returns (bytes memory) {
        return abi.encode(clientId);
    }
}
