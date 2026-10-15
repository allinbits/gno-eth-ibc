// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IGnoLightClientMsgs as Msgs } from "../../src/msgs/IGnoLightClientMsgs.sol";

/// @notice Packs and unpacks Commit.signatures (81-byte CommitSig records) for tests that edit signatures.
library Sigs {
    uint256 internal constant SIZE = 81;

    function decode(bytes memory packed) internal pure returns (Msgs.CommitSig[] memory out) {
        require(packed.length % SIZE == 0, "bad packed signatures");
        out = new Msgs.CommitSig[](packed.length / SIZE);
        for (uint256 i = 0; i < out.length; ++i) {
            uint256 w;
            bytes32 r;
            bytes32 s;
            uint256 v;
            assembly {
                let p := add(add(packed, 32), mul(i, 81))
                w := mload(p)
                r := mload(add(p, 16))
                s := mload(add(p, 48))
                v := byte(0, mload(add(p, 80)))
            }
            out[i] = Msgs.CommitSig({
                validatorIndex: uint16(w >> 240),
                trustedIndex: uint16(w >> 224),
                timeSeconds: uint64(w >> 160),
                timeNanos: uint32(w >> 128),
                r: r,
                s: s,
                v: uint8(v)
            });
        }
    }

    function encode(Msgs.CommitSig[] memory sigs) internal pure returns (bytes memory out) {
        for (uint256 i = 0; i < sigs.length; ++i) {
            Msgs.CommitSig memory c = sigs[i];
            out = bytes.concat(
                out, abi.encodePacked(c.validatorIndex, c.trustedIndex, c.timeSeconds, c.timeNanos, c.r, c.s, c.v)
            );
        }
    }
}
