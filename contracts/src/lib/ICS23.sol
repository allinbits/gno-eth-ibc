// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title ICS23 vector commitment verification
/// @notice A port of the existence and non-existence verification of github.com/cosmos/ics23/go v0.11.0
/// (ops.go, proof.go), parameterised by a ProofSpec.
/// @dev Proofs carry only the variable parts of each op (leaf prefix, inner prefix and suffix). The hash,
/// prehash and length operations come from the spec: the Go verifier requires a proof's ops to equal the
/// spec's anyway, so a proof that disagreed would be rejected there too. Not ported: the IAVL-only leaf/inner
/// prefix validation (validateIavlOps, applied only when the spec equals IavlSpec), compressed and batch
/// proofs, and hash functions the EVM has no precompile for (SHA512, SHA512_256, BLAKE2B/2S, BLAKE3).
/// Because IAVL's variable leaf prefixes are not supported, a leaf prefix must equal the spec's exactly; do
/// not use this library with IAVL specs.
library ICS23 {
    enum HashOp {
        NO_HASH,
        SHA256,
        SHA512,
        KECCAK256,
        RIPEMD160,
        BITCOIN,
        SHA512_256,
        BLAKE2B_512,
        BLAKE2S_256,
        BLAKE3
    }

    enum LengthOp {
        NO_PREFIX,
        VAR_PROTO,
        VAR_RLP,
        FIXED32_BIG,
        FIXED32_LITTLE,
        FIXED64_BIG,
        FIXED64_LITTLE,
        REQUIRE_32_BYTES,
        REQUIRE_64_BYTES
    }

    struct LeafSpec {
        HashOp hash;
        HashOp prehashKey;
        HashOp prehashValue;
        LengthOp length;
        bytes prefix;
    }

    struct InnerSpec {
        uint256[] childOrder;
        uint256 childSize;
        uint256 minPrefixLength;
        uint256 maxPrefixLength;
        bytes emptyChild;
        HashOp hash;
    }

    struct ProofSpec {
        LeafSpec leafSpec;
        InnerSpec innerSpec;
        uint256 maxDepth; // 0 means the ICS23 default of 128
        uint256 minDepth;
        bool prehashKeyBeforeComparison;
    }

    struct InnerOp {
        bytes prefix;
        bytes suffix;
    }

    /// @notice An existence proof. An empty key marks an absent neighbour inside a NonExistenceProof.
    struct ExistenceProof {
        bytes key;
        bytes value;
        bytes leafPrefix;
        InnerOp[] path;
    }

    struct NonExistenceProof {
        bytes key;
        ExistenceProof left;
        ExistenceProof right;
    }

    error UnsupportedHashOp(HashOp op);
    error UnsupportedLengthOp(LengthOp op);
    error LengthOpMismatch();
    error EmptyLeafKey();
    error EmptyLeafValue();
    error EmptyChild();
    error LeafPrefixMismatch();
    error InnerPrefixStartsWithLeafPrefix(uint256 step);
    error InnerPrefixTooShort(uint256 step);
    error InnerPrefixTooLong(uint256 step);
    error InnerSuffixMalformed(uint256 step);
    error InvalidChildSize();
    error PathTooShort(uint256 depth);
    error PathTooLong(uint256 depth);
    error InnerHashTooLong(uint256 step);
    error KeyMismatch();
    error ValueMismatch();
    error RootMismatch();
    error MissingNeighbours();
    error KeyNotRightOfLeft();
    error KeyNotLeftOfRight();
    error LeftNotRightMost();
    error RightNotLeftMost();
    error NotNeighbours();
    error BranchNotInChildOrder(uint256 branch);

    // ------------------------------------------------------------ public API

    /// @notice Reverts unless proof shows key => value under root.
    function verifyMembership(
        ProofSpec memory spec,
        bytes memory root,
        ExistenceProof memory proof,
        bytes memory key,
        bytes memory value
    )
        internal
        pure
    {
        if (!_eq(existenceRoot(spec, proof, key, value), root)) revert RootMismatch();
    }

    /// @notice Reverts unless proof shows key is absent under root.
    function verifyNonMembership(
        ProofSpec memory spec,
        bytes memory root,
        NonExistenceProof memory proof,
        bytes memory key
    )
        internal
        pure
    {
        if (!_eq(nonExistenceRoot(spec, proof, key), root)) revert RootMismatch();
    }

    /// @notice Checks that proof is a valid existence proof of key => value and returns the root it commits
    /// to. The caller compares that root with a trusted one (or feeds it to the next proof of a chain).
    function existenceRoot(
        ProofSpec memory spec,
        ExistenceProof memory proof,
        bytes memory key,
        bytes memory value
    )
        internal
        pure
        returns (bytes memory)
    {
        if (!_eq(proof.key, key)) revert KeyMismatch();
        if (!_eq(proof.value, value)) revert ValueMismatch();
        return calculateExistenceRoot(spec, proof);
    }

    /// @notice Checks that proof is a valid non-existence proof of key and returns the root it commits to:
    /// both neighbours must lead to the same root, and they must be adjacent leaves around key.
    function nonExistenceRoot(
        ProofSpec memory spec,
        NonExistenceProof memory proof,
        bytes memory key
    )
        internal
        pure
        returns (bytes memory root)
    {
        if (!_eq(proof.key, key)) revert KeyMismatch();
        bool hasLeft = proof.left.key.length != 0;
        bool hasRight = proof.right.key.length != 0;
        if (!hasLeft && !hasRight) revert MissingNeighbours();
        if (hasLeft) root = calculateExistenceRoot(spec, proof.left);
        if (hasRight) {
            bytes memory rightRoot = calculateExistenceRoot(spec, proof.right);
            if (hasLeft && !_eq(rightRoot, root)) revert RootMismatch();
            root = rightRoot;
        }

        bytes memory k = _keyForComparison(spec, key);
        if (hasRight && _compare(k, _keyForComparison(spec, proof.right.key)) >= 0) revert KeyNotLeftOfRight();
        if (hasLeft && _compare(k, _keyForComparison(spec, proof.left.key)) <= 0) revert KeyNotRightOfLeft();

        if (!hasLeft) {
            if (!isLeftMost(spec.innerSpec, proof.right.path, proof.right.path.length)) revert RightNotLeftMost();
        } else if (!hasRight) {
            if (!isRightMost(spec.innerSpec, proof.left.path, proof.left.path.length)) revert LeftNotRightMost();
        } else if (!isLeftNeighbor(spec.innerSpec, proof.left.path, proof.right.path)) {
            revert NotNeighbours();
        }
    }

    /// @notice Checks an existence proof against the spec and returns the root it commits to.
    function calculateExistenceRoot(
        ProofSpec memory spec,
        ExistenceProof memory proof
    )
        internal
        pure
        returns (bytes memory res)
    {
        _checkAgainstSpec(spec, proof);
        res = _applyLeaf(spec.leafSpec, proof.leafPrefix, proof.key, proof.value);
        InnerSpec memory ins = spec.innerSpec;
        for (uint256 i = 0; i < proof.path.length; ++i) {
            if (res.length == 0) revert EmptyChild();
            res = _hash(ins.hash, abi.encodePacked(proof.path[i].prefix, res, proof.path[i].suffix));
            if (res.length > ins.childSize && ins.childSize >= 32) revert InnerHashTooLong(i);
        }
    }

    // ------------------------------------------------------------ spec checks

    function _checkAgainstSpec(ProofSpec memory spec, ExistenceProof memory proof) private pure {
        bytes memory leafPrefix = spec.leafSpec.prefix;
        // The leaf prefix must equal the spec's, not merely start with it. Go's ics23 only checks the start
        // and relies on validateIavlOps for IAVL's variable prefixes, which this port does not include. With
        // gno's fixed one-byte prefixes, extra prefix bytes would let a proof of key P ‖ uvarint(len K) ‖ K
        // be relabelled as a proof of K with prefix 0x00 ‖ uvarint(len L) ‖ P: the same leaf preimage.
        if (!_eq(proof.leafPrefix, leafPrefix)) revert LeafPrefixMismatch();

        uint256 depth = proof.path.length;
        if (spec.minDepth > 0 && depth < spec.minDepth) revert PathTooShort(depth);
        uint256 maxDepth = spec.maxDepth == 0 ? 128 : spec.maxDepth;
        if (depth > maxDepth) revert PathTooLong(depth);

        InnerSpec memory ins = spec.innerSpec;
        if (ins.childSize == 0) revert InvalidChildSize();
        uint256 maxPrefix = ins.maxPrefixLength + (ins.childOrder.length - 1) * ins.childSize;
        for (uint256 i = 0; i < depth; ++i) {
            InnerOp memory op = proof.path[i];
            if (_hasPrefix(op.prefix, leafPrefix)) revert InnerPrefixStartsWithLeafPrefix(i);
            if (op.prefix.length < ins.minPrefixLength) revert InnerPrefixTooShort(i);
            if (op.prefix.length > maxPrefix) revert InnerPrefixTooLong(i);
            if (op.suffix.length % ins.childSize != 0) revert InnerSuffixMalformed(i);
        }
    }

    // ------------------------------------------------------------ hashing

    function _applyLeaf(
        LeafSpec memory ls,
        bytes memory prefix,
        bytes memory key,
        bytes memory value
    )
        private
        pure
        returns (bytes memory)
    {
        if (key.length == 0) revert EmptyLeafKey();
        if (value.length == 0) revert EmptyLeafValue();
        bytes memory pkey = _doLength(ls.length, _hashOrNoop(ls.prehashKey, key));
        bytes memory pvalue = _doLength(ls.length, _hashOrNoop(ls.prehashValue, value));
        return _hash(ls.hash, abi.encodePacked(prefix, pkey, pvalue));
    }

    function _hashOrNoop(HashOp op, bytes memory data) private pure returns (bytes memory) {
        if (op == HashOp.NO_HASH) return data;
        return _hash(op, data);
    }

    function _hash(HashOp op, bytes memory data) private pure returns (bytes memory) {
        if (op == HashOp.SHA256) return abi.encodePacked(sha256(data));
        if (op == HashOp.KECCAK256) return abi.encodePacked(keccak256(data));
        if (op == HashOp.RIPEMD160) return abi.encodePacked(ripemd160(data));
        if (op == HashOp.BITCOIN) return abi.encodePacked(ripemd160(abi.encodePacked(sha256(data))));
        revert UnsupportedHashOp(op);
    }

    function _doLength(LengthOp op, bytes memory data) private pure returns (bytes memory) {
        uint256 n = data.length;
        if (op == LengthOp.NO_PREFIX) return data;
        if (op == LengthOp.VAR_PROTO) return abi.encodePacked(_uvarint(n), data);
        if (op == LengthOp.REQUIRE_32_BYTES) {
            if (n != 32) revert LengthOpMismatch();
            return data;
        }
        if (op == LengthOp.REQUIRE_64_BYTES) {
            if (n != 64) revert LengthOpMismatch();
            return data;
        }
        // Like the Go reference, these encode the length modulo the field width; memory cannot hold more.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (op == LengthOp.FIXED32_BIG) return abi.encodePacked(uint32(n), data);
        if (op == LengthOp.FIXED32_LITTLE) return abi.encodePacked(_le(n, 4), data);
        // forge-lint: disable-next-line(unsafe-typecast)
        if (op == LengthOp.FIXED64_BIG) return abi.encodePacked(uint64(n), data);
        if (op == LengthOp.FIXED64_LITTLE) return abi.encodePacked(_le(n, 8), data);
        revert UnsupportedLengthOp(op);
    }

    function _le(uint256 v, uint256 width) private pure returns (bytes memory out) {
        out = new bytes(width);
        for (uint256 i = 0; i < width; ++i) {
            // forge-lint: disable-next-line(unsafe-typecast)
            out[i] = bytes1(uint8(v >> (8 * i))); // keeps the low byte on purpose
        }
    }

    function _uvarint(uint256 v) private pure returns (bytes memory out) {
        uint256 n = 1;
        for (uint256 t = v >> 7; t != 0; t >>= 7) {
            ++n;
        }
        out = new bytes(n);
        for (uint256 i = 0; i < n; ++i) {
            uint256 b = v & 0x7f;
            v >>= 7;
            out[i] = bytes1(uint8(v == 0 ? b : b | 0x80));
        }
    }

    function _keyForComparison(ProofSpec memory spec, bytes memory key) private pure returns (bytes memory) {
        if (!spec.prehashKeyBeforeComparison) return key;
        return _hashOrNoop(spec.leafSpec.prehashKey, key);
    }

    // ------------------------------------------------------------ neighbours

    /// @notice True if the first `len` steps of path all take the left-most branch (or only skip empty ones).
    function isLeftMost(InnerSpec memory spec, InnerOp[] memory path, uint256 len) internal pure returns (bool) {
        (uint256 minPrefix, uint256 maxPrefix, uint256 suffix) = _getPadding(spec, 0);
        for (uint256 i = 0; i < len; ++i) {
            if (!_hasPadding(path[i], minPrefix, maxPrefix, suffix) && !_leftBranchesAreEmpty(spec, path[i])) {
                return false;
            }
        }
        return true;
    }

    /// @notice True if the first `len` steps of path all take the right-most branch (or only skip empty ones).
    function isRightMost(InnerSpec memory spec, InnerOp[] memory path, uint256 len) internal pure returns (bool) {
        (uint256 minPrefix, uint256 maxPrefix, uint256 suffix) = _getPadding(spec, spec.childOrder.length - 1);
        for (uint256 i = 0; i < len; ++i) {
            if (!_hasPadding(path[i], minPrefix, maxPrefix, suffix) && !_rightBranchesAreEmpty(spec, path[i])) {
                return false;
            }
        }
        return true;
    }

    /// @notice True if left and right are paths to adjacent leaves.
    function isLeftNeighbor(
        InnerSpec memory spec,
        InnerOp[] memory left,
        InnerOp[] memory right
    )
        internal
        pure
        returns (bool)
    {
        uint256 l = left.length;
        uint256 r = right.length;
        if (l == 0 || r == 0) return false;
        // drop the shared top of both paths
        while (_eq(left[l - 1].prefix, right[r - 1].prefix) && _eq(left[l - 1].suffix, right[r - 1].suffix)) {
            --l;
            --r;
            if (l == 0 || r == 0) return false;
        }
        (bool okL, uint256 leftIdx) = _orderFromPadding(spec, left[l - 1]);
        (bool okR, uint256 rightIdx) = _orderFromPadding(spec, right[r - 1]);
        if (!okL || !okR || rightIdx != leftIdx + 1) return false;
        return isRightMost(spec, left, l - 1) && isLeftMost(spec, right, r - 1);
    }

    function _getPosition(uint256[] memory order, uint256 branch) private pure returns (uint256) {
        for (uint256 i = 0; i < order.length; ++i) {
            if (order[i] == branch) return i;
        }
        revert BranchNotInChildOrder(branch);
    }

    function _getPadding(
        InnerSpec memory spec,
        uint256 branch
    )
        private
        pure
        returns (uint256 minPrefix, uint256 maxPrefix, uint256 suffix)
    {
        uint256 idx = _getPosition(spec.childOrder, branch);
        uint256 prefix = idx * spec.childSize;
        minPrefix = prefix + spec.minPrefixLength;
        maxPrefix = prefix + spec.maxPrefixLength;
        suffix = (spec.childOrder.length - 1 - idx) * spec.childSize;
    }

    function _hasPadding(
        InnerOp memory op,
        uint256 minPrefix,
        uint256 maxPrefix,
        uint256 suffix
    )
        private
        pure
        returns (bool)
    {
        return op.prefix.length >= minPrefix && op.prefix.length <= maxPrefix && op.suffix.length == suffix;
    }

    function _orderFromPadding(InnerSpec memory spec, InnerOp memory op) private pure returns (bool, uint256) {
        for (uint256 branch = 0; branch < spec.childOrder.length; ++branch) {
            (uint256 minP, uint256 maxP, uint256 suf) = _getPadding(spec, branch);
            if (_hasPadding(op, minP, maxP, suf)) return (true, branch);
        }
        return (false, 0);
    }

    function _leftBranchesAreEmpty(InnerSpec memory spec, InnerOp memory op) private pure returns (bool) {
        (bool ok, uint256 leftBranches) = _orderFromPadding(spec, op);
        if (!ok || leftBranches == 0) return false;
        uint256 size = spec.childSize;
        if (op.prefix.length < leftBranches * size) return false;
        uint256 actualPrefix = op.prefix.length - leftBranches * size;
        for (uint256 i = 0; i < leftBranches; ++i) {
            uint256 from = actualPrefix + _getPosition(spec.childOrder, i) * size;
            if (!_sliceEq(op.prefix, from, size, spec.emptyChild)) return false;
        }
        return true;
    }

    function _rightBranchesAreEmpty(InnerSpec memory spec, InnerOp memory op) private pure returns (bool) {
        (bool ok, uint256 idx) = _orderFromPadding(spec, op);
        if (!ok) return false;
        uint256 rightBranches = spec.childOrder.length - 1 - idx;
        if (rightBranches == 0) return false;
        uint256 size = spec.childSize;
        if (op.suffix.length != rightBranches * size) return false;
        for (uint256 i = 0; i < rightBranches; ++i) {
            uint256 from = _getPosition(spec.childOrder, i) * size;
            if (!_sliceEq(op.suffix, from, size, spec.emptyChild)) return false;
        }
        return true;
    }

    // ------------------------------------------------------------ bytes helpers

    function _eq(bytes memory a, bytes memory b) private pure returns (bool) {
        return a.length == b.length && keccak256(a) == keccak256(b);
    }

    /// @notice bytes.Equal(want, data[from:from+len]); false when the slice is out of range.
    function _sliceEq(bytes memory data, uint256 from, uint256 len, bytes memory want) private pure returns (bool) {
        if (want.length != len || from + len > data.length) return false;
        bytes32 h;
        assembly ("memory-safe") {
            h := keccak256(add(add(data, 32), from), len)
        }
        return h == keccak256(want);
    }

    function _hasPrefix(bytes memory data, bytes memory prefix) private pure returns (bool) {
        return _sliceEq(data, 0, prefix.length, prefix);
    }

    /// @notice bytes.Compare: -1, 0 or 1.
    function _compare(bytes memory a, bytes memory b) private pure returns (int256) {
        uint256 n = a.length < b.length ? a.length : b.length;
        for (uint256 i = 0; i < n; ++i) {
            if (a[i] < b[i]) return -1;
            if (a[i] > b[i]) return 1;
        }
        if (a.length < b.length) return -1;
        if (a.length > b.length) return 1;
        return 0;
    }
}
