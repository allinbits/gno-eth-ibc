// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IGnoLightClientMsgs as Msgs } from "../src/msgs/IGnoLightClientMsgs.sol";
import { Tm2Encoding } from "../src/lib/Tm2Encoding.sol";
import { Tm2Merkle } from "../src/lib/Tm2Merkle.sol";
import { Fixtures } from "./utils/Fixtures.sol";

/// @notice Byte-equality of the Solidity amino encodings with what tm2 (Go) produced for the fixtures.
contract Tm2EncodingTest is Fixtures {
    function setUp() public {
        _loadFixtures();
    }

    function _valSetHash(Msgs.Validator[] memory vals) internal pure returns (bytes32) {
        bytes32[] memory leaves = new bytes32[](vals.length);
        for (uint256 i = 0; i < vals.length; ++i) {
            (bytes memory compressed,) = Tm2Encoding.parsePubKey(vals[i].pubKey);
            leaves[i] = Tm2Merkle.leafHash(Tm2Encoding.validatorLeaf(compressed, vals[i].votingPower));
        }
        return Tm2Merkle.rootFromLeafHashes(leaves);
    }

    function test_headerLeavesMatchGo() public view {
        Msgs.HeaderFields memory hf = _header("h11").signedHeader;
        bytes[] memory leaves = vm.parseJsonBytesArray(fx, ".encoding.headerLeaves");
        assertEq(leaves.length, 16);
        assertEq(Tm2Encoding.stringLeaf(bytes(vm.parseJsonString(fx, ".chainId"))), leaves[1], "ChainID");
        assertEq(Tm2Encoding.heightLeaf(hf.height), leaves[2], "Height");
        assertEq(Tm2Encoding.timeLeaf(hf.timeSeconds, hf.timeNanos), leaves[3], "Time");
        assertEq(Tm2Encoding.hashLeaf(_valSetHash(_header("h11").validatorSet)), leaves[10], "ValidatorsHash");
        assertEq(Tm2Encoding.hashLeaf(hf.nextValidatorsHash), leaves[11], "NextValidatorsHash");
        assertEq(Tm2Encoding.hashLeaf(hf.appHash), leaves[13], "AppHash");
        // the siblings the relayer supplies are hashes of the other Go leaves
        assertEq(hf.versionLeafHash, Tm2Merkle.leafHash(leaves[0]));
        assertEq(hf.consensusLeafHash, Tm2Merkle.leafHash(leaves[12]));
        assertEq(
            hf.lastCommitAndDataHash, Tm2Merkle.innerHash(Tm2Merkle.leafHash(leaves[8]), Tm2Merkle.leafHash(leaves[9]))
        );
    }

    function test_headerHashMatchesGo() public view {
        Msgs.Header memory h = _header("h11");
        bytes32 got = Tm2Encoding.headerHash(
            h.signedHeader, bytes(vm.parseJsonString(fx, ".chainId")), _valSetHash(h.validatorSet)
        );
        assertEq(got, vm.parseJsonBytes32(fx, ".encoding.headerHash"));
        assertEq(got, _updateBytes32("h11", "blockHash"));
    }

    function test_voteSignBytesMatchGo() public view {
        bytes[] memory want = vm.parseJsonBytesArray(fx, ".encoding.signBytes");
        bytes memory chainId = bytes(vm.parseJsonString(fx, ".chainId"));
        string[2] memory names = ["h11", "h12"];
        uint256 k = 0;
        for (uint256 n = 0; n < 2; ++n) {
            Msgs.Header memory h = _header(names[n]);
            bytes32 blockHash = _updateBytes32(names[n], "blockHash");
            (bytes memory pre, bytes memory post) = Tm2Encoding.voteSignBytesParts(
                chainId, h.signedHeader.height, h.commit.round, blockHash, h.commit.partSetTotal, h.commit.partSetHash
            );
            for (uint256 i = 0; i < h.commit.signatures.length; ++i) {
                Msgs.CommitSig memory s = h.commit.signatures[i];
                assertEq(Tm2Encoding.voteSignBytes(pre, post, s.timeSeconds, s.timeNanos), want[k++]);
            }
        }
        assertEq(k, want.length);
        // h12 commits at round 1, and every commit has one vote with a zero-nanosecond timestamp
        assertEq(_header("h12").commit.round, 1);
        assertEq(
            _header("h11").commit.signatures[0].timeNanos == 0 || _header("h11").commit.signatures[1].timeNanos == 0
                || _header("h11").commit.signatures[2].timeNanos == 0,
            true
        );
    }

    function test_validatorEncodingMatchesGo() public view {
        Msgs.Validator[] memory vals = _header("h11").validatorSet;
        bytes[] memory want = vm.parseJsonBytesArray(fx, ".encoding.validatorLeaves");
        assertEq(vals.length, 3);
        for (uint256 i = 0; i < vals.length; ++i) {
            (bytes memory compressed,) = Tm2Encoding.parsePubKey(vals[i].pubKey);
            assertEq(Tm2Encoding.validatorLeaf(compressed, vals[i].votingPower), want[i]);
        }
        assertEq(_valSetHash(vals), vm.parseJsonBytes32(fx, ".encoding.validatorSetHash"));
        Msgs.Validator[] memory four = _header("h13").validatorSet;
        assertEq(four.length, 4);
        assertEq(_valSetHash(four), vm.parseJsonBytes32(fx, ".encoding.validators4Hash"));
    }

    function test_parsePubKeyRejectsOffCurvePoint() public {
        bytes memory pk = _header("h11").validatorSet[0].pubKey;
        pk[63] = bytes1(uint8(pk[63]) ^ 1);
        vm.expectRevert(Tm2Encoding.InvalidPublicKey.selector);
        this.parsePubKey(pk);
    }

    function parsePubKey(bytes memory pk) external pure returns (bytes memory, address) {
        return Tm2Encoding.parsePubKey(pk);
    }

    function test_uvarint() public pure {
        assertEq(Tm2Encoding.uvarint(0), hex"00");
        assertEq(Tm2Encoding.uvarint(127), hex"7f");
        assertEq(Tm2Encoding.uvarint(128), hex"8001");
        assertEq(Tm2Encoding.uvarint(300), hex"ac02");
        assertEq(Tm2Encoding.int64Varint(300), hex"d804");
    }

    function test_splitPoint() public pure {
        assertEq(Tm2Merkle.splitPoint(2), 1);
        assertEq(Tm2Merkle.splitPoint(3), 2);
        assertEq(Tm2Merkle.splitPoint(4), 2);
        assertEq(Tm2Merkle.splitPoint(5), 4);
        assertEq(Tm2Merkle.splitPoint(16), 8);
        assertEq(Tm2Merkle.splitPoint(17), 16);
    }
}
