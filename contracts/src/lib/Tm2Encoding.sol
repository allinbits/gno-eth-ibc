// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IGnoLightClientMsgs as Msgs } from "../msgs/IGnoLightClientMsgs.sol";
import { Tm2Merkle } from "./Tm2Merkle.sol";

/// @title tm2 amino encoding
/// @notice The few amino binary encodings the light client must reproduce byte for byte: six header leaves,
/// CanonicalVote sign bytes and validator hash leaves. Only positive integers are ever encoded, so tm2's
/// zigzag varint for int64 is 2 * value and plain uvarints never see a negative.
library Tm2Encoding {
    /// @notice amino name of tm2's secp256k1 public key ("/tm.PubKeySecp256k1"), registered in
    /// tm2/pkg/crypto/secp256k1/package.go.
    bytes internal constant SECP256K1_PUBKEY_TYPE_URL = "/tm.PubKeySecp256k1";

    uint256 private constant SECP256K1_P = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F;
    uint256 private constant MAX_INT64 = 0x7FFFFFFFFFFFFFFF;

    /// @notice Precommit, tm2/pkg/bft/types/signed_msg_type.go
    uint8 internal constant PRECOMMIT_TYPE = 0x02;

    error InvalidPublicKey();
    error ValueOutOfRange();

    // ---------------------------------------------------------------- primitives

    /// @notice Unsigned LEB128 varint, as protobuf and amino write it.
    function uvarint(uint256 v) internal pure returns (bytes memory out) {
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

    /// @notice amino int64 (zigzag varint) of a positive value.
    function int64Varint(uint256 v) internal pure returns (bytes memory) {
        if (v > MAX_INT64) revert ValueOutOfRange();
        return uvarint(v << 1);
    }

    function _le64(uint64 v) private pure returns (bytes8) {
        uint64 r = 0;
        for (uint256 i = 0; i < 8; ++i) {
            r = (r << 8) | (v & 0xff);
            v >>= 8;
        }
        return bytes8(r);
    }

    /// @notice Body of a google.protobuf.Timestamp-shaped amino time: zero fields are omitted.
    function timestampBody(uint64 seconds_, uint32 nanos) internal pure returns (bytes memory) {
        if (seconds_ > MAX_INT64 || nanos >= 1e9) revert ValueOutOfRange();
        bytes memory s = seconds_ == 0 ? bytes("") : abi.encodePacked(bytes1(0x08), uvarint(seconds_));
        bytes memory n = nanos == 0 ? bytes("") : abi.encodePacked(bytes1(0x10), uvarint(nanos));
        return abi.encodePacked(s, n);
    }

    // ---------------------------------------------------------------- header

    /// @notice amino.MustMarshal(string): field 1, length-prefixed.
    function stringLeaf(bytes memory s) internal pure returns (bytes memory) {
        if (s.length == 0) return "";
        return abi.encodePacked(bytes1(0x0a), uvarint(s.length), s);
    }

    /// @notice amino.MustMarshal(int64) of a positive height.
    function heightLeaf(uint64 height) internal pure returns (bytes memory) {
        if (height == 0) return "";
        return abi.encodePacked(bytes1(0x08), int64Varint(height));
    }

    /// @notice amino.MustMarshal(time.Time): the bare timestamp struct.
    function timeLeaf(uint64 seconds_, uint32 nanos) internal pure returns (bytes memory) {
        return timestampBody(seconds_, nanos);
    }

    /// @notice amino.MustMarshal([]byte) of a 32-byte hash.
    function hashLeaf(bytes32 h) internal pure returns (bytes memory) {
        return abi.encodePacked(bytes2(0x0a20), h);
    }

    /// @notice tm2 Header.Hash (tm2/pkg/bft/types/block.go): simple Merkle root of the 16 amino leaves.
    /// @param hf Header fields and the sibling hashes of the leaves not rebuilt here
    /// @param chainId Chain ID the header must carry
    /// @param validatorsHash Hash of the header's validator set, computed by the caller
    function headerHash(
        Msgs.HeaderFields memory hf,
        bytes memory chainId,
        bytes32 validatorsHash
    )
        internal
        pure
        returns (bytes32)
    {
        bytes32 first4 = Tm2Merkle.innerHash(
            Tm2Merkle.innerHash(hf.versionLeafHash, Tm2Merkle.leafHash(stringLeaf(chainId))),
            Tm2Merkle.innerHash(
                Tm2Merkle.leafHash(heightLeaf(hf.height)), Tm2Merkle.leafHash(timeLeaf(hf.timeSeconds, hf.timeNanos))
            )
        );
        bytes32 vals = Tm2Merkle.innerHash(
            Tm2Merkle.leafHash(hashLeaf(validatorsHash)), Tm2Merkle.leafHash(hashLeaf(hf.nextValidatorsHash))
        );
        bytes32 right = Tm2Merkle.innerHash(
            Tm2Merkle.innerHash(hf.lastCommitAndDataHash, vals),
            Tm2Merkle.innerHash(
                Tm2Merkle.innerHash(hf.consensusLeafHash, Tm2Merkle.leafHash(hashLeaf(hf.appHash))),
                hf.resultsAndProposerHash
            )
        );
        return Tm2Merkle.innerHash(Tm2Merkle.innerHash(first4, hf.txsAndLastBlockIDHash), right);
    }

    // ---------------------------------------------------------------- votes

    /// @notice A reusable buffer holding the CanonicalVote sign bytes of one commit. Every precommit of a commit
    /// shares all fields but the timestamp (tm2/pkg/bft/types/block.go Commit.VoteSignBytes), so the shared
    /// prefix is written once and each vote only rewrites timestamp, chain ID and length prefix in place.
    /// CanonicalVote (canonical.go): 1 Type uvarint, 2 Height fixed64, 3 Round fixed64,
    /// 4 BlockID {1 Hash, 2 PartsHeader {1 Total uvarint, 2 Hash}}, 5 Timestamp, 6 ChainID. Zero fields omitted.
    /// @dev Layout of buf: 32 bytes of headroom (room for the length word of the returned view), 2 bytes for the
    /// sign bytes' uvarint length prefix, the shared prefix, then the per-vote tail.
    struct VoteBuffer {
        bytes buf;
        uint256 preLen;
        bytes chainId;
    }

    /// @notice Largest timestamp field: tag, length, 0x08 + 10-byte varint, 0x10 + 5-byte varint.
    uint256 private constant MAX_TS_FIELD = 19;

    function newVoteBuffer(
        bytes memory chainId,
        uint64 height,
        uint32 round,
        bytes32 blockHash,
        uint32 partSetTotal,
        bytes32 partSetHash
    )
        internal
        pure
        returns (VoteBuffer memory b)
    {
        bytes memory psh = abi.encodePacked(
            partSetTotal == 0 ? bytes("") : abi.encodePacked(bytes1(0x08), uvarint(partSetTotal)),
            bytes2(0x1220),
            partSetHash
        );
        bytes memory blockId = abi.encodePacked(bytes2(0x0a20), blockHash, bytes1(0x12), uvarint(psh.length), psh);
        bytes memory pre = abi.encodePacked(
            bytes1(0x08),
            bytes1(PRECOMMIT_TYPE),
            bytes1(0x11),
            _le64(height),
            round == 0 ? bytes("") : abi.encodePacked(bytes1(0x19), _le64(round)),
            bytes1(0x22),
            uvarint(blockId.length),
            blockId
        );
        bytes memory post = abi.encodePacked(bytes1(0x32), uvarint(chainId.length), chainId);
        b.buf = new bytes(34 + pre.length + MAX_TS_FIELD + post.length);
        b.preLen = pre.length;
        b.chainId = post;
        assembly ("memory-safe") {
            mcopy(add(mload(b), 66), add(pre, 32), mload(pre))
        }
    }

    /// @notice amino.MarshalSized(CanonicalVote) for a vote with this timestamp. The result aliases the buffer:
    /// it is valid until the next call on the same buffer.
    function voteSignBytes(VoteBuffer memory b, uint64 seconds_, uint32 nanos)
        internal
        pure
        returns (bytes memory out)
    {
        if (seconds_ > MAX_INT64 || nanos >= 1e9) revert ValueOutOfRange();
        bytes memory buf = b.buf;
        bytes memory post = b.chainId;
        uint256 preLen = b.preLen;
        assembly ("memory-safe") {
            function putVarint(p, v) -> q {
                for { } gt(v, 0x7f) { } {
                    mstore8(p, or(and(v, 0x7f), 0x80))
                    v := shr(7, v)
                    p := add(p, 1)
                }
                mstore8(p, v)
                q := add(p, 1)
            }
            let body := add(buf, 66) // after length word, headroom and prefix room
            let tag := add(body, preLen)
            let q := add(tag, 2)
            if seconds_ {
                mstore8(q, 0x08)
                q := putVarint(add(q, 1), seconds_)
            }
            if nanos {
                mstore8(q, 0x10)
                q := putVarint(add(q, 1), nanos)
            }
            mstore8(tag, 0x2a)
            mstore8(add(tag, 1), sub(q, add(tag, 2)))
            let postLen := mload(post)
            mcopy(q, add(post, 32), postLen)
            let end := add(q, postLen)
            let bodyLen := sub(end, body)
            let start
            switch lt(bodyLen, 128)
            case 1 {
                start := sub(body, 1)
                mstore8(start, bodyLen)
            }
            default {
                // the shared prefix is far below 16384 bytes, so two varint bytes always suffice
                start := sub(body, 2)
                mstore8(start, or(and(bodyLen, 0x7f), 0x80))
                mstore8(add(start, 1), shr(7, bodyLen))
            }
            out := sub(start, 32)
            mstore(out, sub(end, start))
        }
    }

    // ---------------------------------------------------------------- validators

    /// @notice Validates a 64-byte uncompressed key and returns its 33-byte compressed form and Ethereum
    /// address. The point must be on the curve, so the compressed key the chain hashes and the address
    /// ecrecover returns name the same key.
    function parsePubKey(bytes memory pubKey) internal pure returns (bytes memory compressed, address addr) {
        if (pubKey.length != 64) revert InvalidPublicKey();
        uint256 x;
        uint256 y;
        assembly ("memory-safe") {
            x := mload(add(pubKey, 32))
            y := mload(add(pubKey, 64))
        }
        if (x >= SECP256K1_P || y >= SECP256K1_P) revert InvalidPublicKey();
        uint256 rhs = addmod(mulmod(mulmod(x, x, SECP256K1_P), x, SECP256K1_P), 7, SECP256K1_P);
        if (mulmod(y, y, SECP256K1_P) != rhs) revert InvalidPublicKey();
        compressed = abi.encodePacked(bytes1(uint8(0x02 | (y & 1))), bytes32(x));
        addr = address(uint160(uint256(keccak256(pubKey))));
    }

    /// @notice tm2 Validator.Bytes (validator.go): amino of struct{PubKey crypto.PubKey; VotingPower int64}, the
    /// key as an amino Any {1 TypeURL, 2 Value = PubKeySecp256k1 bytes}.
    function validatorLeaf(bytes memory compressedKey, uint64 votingPower) internal pure returns (bytes memory) {
        bytes memory keyBytes = abi.encodePacked(bytes1(0x0a), uvarint(compressedKey.length), compressedKey);
        bytes memory any = abi.encodePacked(
            bytes1(0x0a),
            uvarint(SECP256K1_PUBKEY_TYPE_URL.length),
            SECP256K1_PUBKEY_TYPE_URL,
            bytes1(0x12),
            uvarint(keyBytes.length),
            keyBytes
        );
        return abi.encodePacked(
            bytes1(0x0a),
            uvarint(any.length),
            any,
            votingPower == 0 ? bytes("") : abi.encodePacked(bytes1(0x10), int64Varint(votingPower))
        );
    }
}
