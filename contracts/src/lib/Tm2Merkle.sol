// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title tm2 simple Merkle tree
/// @notice Port of tm2/pkg/crypto/merkle SimpleHashFromByteSlices: leaf = sha256(0x00 || leaf),
/// inner = sha256(0x01 || left || right), split at the largest power of two below the item count.
library Tm2Merkle {
    error EmptyMerkleTree();

    function leafHash(bytes memory leaf) internal pure returns (bytes32) {
        return sha256(abi.encodePacked(bytes1(0x00), leaf));
    }

    function innerHash(bytes32 left, bytes32 right) internal pure returns (bytes32) {
        return sha256(abi.encodePacked(bytes1(0x01), left, right));
    }

    /// @notice Root of a tree whose leaves are already hashed with leafHash.
    function rootFromLeafHashes(bytes32[] memory leafHashes) internal pure returns (bytes32) {
        if (leafHashes.length == 0) revert EmptyMerkleTree();
        return _root(leafHashes, 0, leafHashes.length);
    }

    function _root(bytes32[] memory h, uint256 start, uint256 n) private pure returns (bytes32) {
        if (n == 1) return h[start];
        uint256 k = splitPoint(n);
        return innerHash(_root(h, start, k), _root(h, start + k, n - k));
    }

    /// @notice Largest power of two strictly less than n, for n >= 2.
    function splitPoint(uint256 n) internal pure returns (uint256 k) {
        k = 1;
        while (k << 1 < n) {
            k <<= 1;
        }
    }
}
