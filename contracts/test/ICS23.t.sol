// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";

import { ICS23 } from "../src/lib/ICS23.sol";
import { GnoProofSpecs } from "../src/lib/GnoProofSpecs.sol";
import { IGnoLightClientMsgs as Msgs } from "../src/msgs/IGnoLightClientMsgs.sol";

/// @notice The generic ICS23 verifier against the official cosmos/ics23 vectors (IAVL, Tendermint and SMT specs)
/// and against spec violations in real gno bptree proofs.
contract ICS23Test is Test {
    string internal vectors;
    string internal gno;

    function setUp() public {
        vectors = vm.readFile("test/fixtures/ics23_vectors.json");
        gno = vm.readFile("test/fixtures/gno.json");
    }

    function iavlSpec() internal pure returns (ICS23.ProofSpec memory spec) {
        spec = GnoProofSpecs.tendermintSpec();
        spec.innerSpec.minPrefixLength = 4;
        spec.innerSpec.maxPrefixLength = 12;
        spec.innerSpec.childSize = 33;
    }

    function smtSpec() internal pure returns (ICS23.ProofSpec memory spec) {
        spec = GnoProofSpecs.tendermintSpec();
        spec.leafSpec.prehashKey = ICS23.HashOp.SHA256;
        spec.leafSpec.length = ICS23.LengthOp.NO_PREFIX;
        spec.innerSpec.emptyChild = new bytes(32);
        spec.maxDepth = 256;
        spec.prehashKeyBeforeComparison = true;
    }

    function _spec(string memory name) internal pure returns (ICS23.ProofSpec memory) {
        bytes32 h = keccak256(bytes(name));
        if (h == keccak256("iavl")) return iavlSpec();
        if (h == keccak256("tendermint")) return GnoProofSpecs.tendermintSpec();
        if (h == keccak256("smt")) return smtSpec();
        revert("unknown spec");
    }

    // external wrappers so expectRevert can catch library reverts
    function verifyExist(
        ICS23.ProofSpec memory spec,
        bytes memory root,
        bytes memory proof,
        bytes memory key,
        bytes memory value
    )
        external
        pure
    {
        ICS23.verifyMembership(spec, root, abi.decode(proof, (ICS23.ExistenceProof)), key, value);
    }

    function verifyNonExist(
        ICS23.ProofSpec memory spec,
        bytes memory root,
        bytes memory proof,
        bytes memory key
    )
        external
        pure
    {
        ICS23.verifyNonMembership(spec, root, abi.decode(proof, (ICS23.NonExistenceProof)), key);
    }

    function _isIavl(string memory base) internal view returns (bool) {
        return keccak256(bytes(vm.parseJsonString(vectors, string.concat(base, ".spec")))) == keccak256("iavl");
    }

    /// The tendermint and SMT vectors verify; IAVL's are refused (see test_officialVectors_iavlRefused).
    function test_officialVectors() public view {
        for (uint256 i = 0; i < 18; ++i) {
            string memory base = string.concat(".vectors[", vm.toString(i), "]");
            if (_isIavl(base)) continue;
            ICS23.ProofSpec memory spec = _spec(vm.parseJsonString(vectors, string.concat(base, ".spec")));
            bytes memory root = vm.parseJsonBytes(vectors, string.concat(base, ".root"));
            bytes memory key = vm.parseJsonBytes(vectors, string.concat(base, ".key"));
            bytes memory proof = vm.parseJsonBytes(vectors, string.concat(base, ".proof"));
            if (vm.parseJsonBool(vectors, string.concat(base, ".exist"))) {
                this.verifyExist(spec, root, proof, key, vm.parseJsonBytes(vectors, string.concat(base, ".value")));
            } else {
                this.verifyNonExist(spec, root, proof, key);
            }
        }
    }

    /// IAVL encodes height, size and version in its leaf prefixes, which only Go's validateIavlOps can check;
    /// this library requires the spec's exact leaf prefix, so it refuses every IAVL proof.
    function test_officialVectors_iavlRefused() public {
        uint256 seen;
        for (uint256 i = 0; i < 18; ++i) {
            string memory base = string.concat(".vectors[", vm.toString(i), "]");
            if (!_isIavl(base)) continue;
            ++seen;
            ICS23.ProofSpec memory spec = _spec("iavl");
            bytes memory root = vm.parseJsonBytes(vectors, string.concat(base, ".root"));
            bytes memory key = vm.parseJsonBytes(vectors, string.concat(base, ".key"));
            bytes memory proof = vm.parseJsonBytes(vectors, string.concat(base, ".proof"));
            vm.expectRevert(ICS23.LeafPrefixMismatch.selector);
            if (vm.parseJsonBool(vectors, string.concat(base, ".exist"))) {
                this.verifyExist(spec, root, proof, key, vm.parseJsonBytes(vectors, string.concat(base, ".value")));
            } else {
                this.verifyNonExist(spec, root, proof, key);
            }
        }
        assertGt(seen, 0);
    }

    function test_officialVectors_wrongRootRejected() public {
        for (uint256 i = 0; i < 18; ++i) {
            string memory base = string.concat(".vectors[", vm.toString(i), "]");
            if (_isIavl(base)) continue;
            ICS23.ProofSpec memory spec = _spec(vm.parseJsonString(vectors, string.concat(base, ".spec")));
            bytes memory root = vm.parseJsonBytes(vectors, string.concat(base, ".root"));
            root[0] ^= 0x01;
            bytes memory key = vm.parseJsonBytes(vectors, string.concat(base, ".key"));
            bytes memory proof = vm.parseJsonBytes(vectors, string.concat(base, ".proof"));
            vm.expectRevert(ICS23.RootMismatch.selector);
            if (vm.parseJsonBool(vectors, string.concat(base, ".exist"))) {
                this.verifyExist(spec, root, proof, key, vm.parseJsonBytes(vectors, string.concat(base, ".value")));
            } else {
                this.verifyNonExist(spec, root, proof, key);
            }
        }
    }

    function test_vectorsRejectedUnderTheWrongSpec() public {
        string memory base = ".vectors[0]";
        assertEq(vm.parseJsonString(vectors, string.concat(base, ".spec")), "iavl");
        bytes memory proof = vm.parseJsonBytes(vectors, string.concat(base, ".proof"));
        // an IAVL proof does not fit the Tendermint spec: its leaf prefix is longer than the spec's
        vm.expectRevert(ICS23.LeafPrefixMismatch.selector);
        this.verifyExist(
            GnoProofSpecs.tendermintSpec(),
            vm.parseJsonBytes(vectors, string.concat(base, ".root")),
            proof,
            vm.parseJsonBytes(vectors, string.concat(base, ".key")),
            vm.parseJsonBytes(vectors, string.concat(base, ".value"))
        );
    }

    // ------------------------------------------------------------ gno bptree spec checks

    function _bptreeProof() internal view returns (ICS23.ExistenceProof memory p, bytes memory root) {
        Msgs.MembershipProof memory mp =
            abi.decode(vm.parseJsonBytes(gno, ".proofs.membership[0].proof"), (Msgs.MembershipProof));
        p = mp.storeProof;
        root = mp.rootProof.value; // the main store root
    }

    function test_bptree_validProof() public view {
        (ICS23.ExistenceProof memory p, bytes memory root) = _bptreeProof();
        ICS23.ProofSpec memory spec = GnoProofSpecs.bptreeSpec(); // before expectRevert: it calls sha256
        this.verifyExist(spec, root, abi.encode(p), p.key, p.value);
    }

    function test_bptree_belowMinDepth() public {
        (ICS23.ExistenceProof memory p, bytes memory root) = _bptreeProof();
        ICS23.ProofSpec memory spec = GnoProofSpecs.bptreeSpec(); // before expectRevert: it calls sha256
        ICS23.InnerOp[] memory path = new ICS23.InnerOp[](4);
        for (uint256 i = 0; i < 4; ++i) {
            path[i] = p.path[i];
        }
        p.path = path;
        vm.expectRevert(abi.encodeWithSelector(ICS23.PathTooShort.selector, 4));
        this.verifyExist(spec, root, abi.encode(p), p.key, p.value);
    }

    function test_bptree_leafPrefixMismatch() public {
        (ICS23.ExistenceProof memory p, bytes memory root) = _bptreeProof();
        ICS23.ProofSpec memory spec = GnoProofSpecs.bptreeSpec(); // before expectRevert: it calls sha256
        p.leafPrefix = hex"01";
        vm.expectRevert(ICS23.LeafPrefixMismatch.selector);
        this.verifyExist(spec, root, abi.encode(p), p.key, p.value);
    }

    /// A leaf prefix longer than the spec's would let a proof of one key be relabelled as a proof of another:
    /// with L = P ‖ uvarint(len K) ‖ K, the proof of (L, v) under prefix 0x00 has the same leaf preimage as
    /// (K, v) under prefix 0x00 ‖ uvarint(len L) ‖ P. Realm param names are arbitrary, so anyone could store a
    /// value under such an L and pass it off as a core commitment K.
    function test_bptree_relabelledLeafPrefixRejected() public {
        (ICS23.ExistenceProof memory p,) = _bptreeProof();
        ICS23.ProofSpec memory spec = GnoProofSpecs.bptreeSpec(); // before expectRevert: it calls sha256
        bytes memory target = "/pv/vm:gno.land/r/aib/ibc/core:commitments/client-0/1";
        bytes memory attackerPrefix = "/pv/vm:gno.land/r/attacker:";
        bytes memory forgedKey = abi.encodePacked(attackerPrefix, uint8(target.length), target);
        p.key = forgedKey;
        p.leafPrefix = hex"00";
        bytes memory root = ICS23.calculateExistenceRoot(spec, p); // the root an honest proof of forgedKey has

        ICS23.ExistenceProof memory relabelled = p;
        relabelled.key = target;
        relabelled.leafPrefix = abi.encodePacked(hex"00", uint8(forgedKey.length), attackerPrefix);
        vm.expectRevert(ICS23.LeafPrefixMismatch.selector);
        this.verifyExist(spec, root, abi.encode(relabelled), relabelled.key, relabelled.value);
    }

    function test_bptree_leafPrefixLongerThanSpecRejected() public {
        (ICS23.ExistenceProof memory p, bytes memory root) = _bptreeProof();
        ICS23.ProofSpec memory spec = GnoProofSpecs.bptreeSpec(); // before expectRevert: it calls sha256
        p.leafPrefix = hex"0000";
        vm.expectRevert(ICS23.LeafPrefixMismatch.selector);
        this.verifyExist(spec, root, abi.encode(p), p.key, p.value);
    }

    function test_bptree_innerOpDisguisedAsLeaf() public {
        (ICS23.ExistenceProof memory p, bytes memory root) = _bptreeProof();
        ICS23.ProofSpec memory spec = GnoProofSpecs.bptreeSpec(); // before expectRevert: it calls sha256
        p.path[0].prefix[0] = 0x00;
        vm.expectRevert(abi.encodeWithSelector(ICS23.InnerPrefixStartsWithLeafPrefix.selector, 0));
        this.verifyExist(spec, root, abi.encode(p), p.key, p.value);
    }

    function test_bptree_innerPrefixTooLong() public {
        (ICS23.ExistenceProof memory p, bytes memory root) = _bptreeProof();
        ICS23.ProofSpec memory spec = GnoProofSpecs.bptreeSpec(); // before expectRevert: it calls sha256
        p.path[0].prefix = bytes.concat(p.path[0].prefix, new bytes(33));
        vm.expectRevert(abi.encodeWithSelector(ICS23.InnerPrefixTooLong.selector, 0));
        this.verifyExist(spec, root, abi.encode(p), p.key, p.value);
    }

    function test_bptree_malformedSuffix() public {
        (ICS23.ExistenceProof memory p, bytes memory root) = _bptreeProof();
        ICS23.ProofSpec memory spec = GnoProofSpecs.bptreeSpec(); // before expectRevert: it calls sha256
        p.path[0].suffix = bytes.concat(p.path[0].suffix, hex"00");
        vm.expectRevert(abi.encodeWithSelector(ICS23.InnerSuffixMalformed.selector, 0));
        this.verifyExist(spec, root, abi.encode(p), p.key, p.value);
    }

    function test_bptree_emptyValueRejected() public {
        (ICS23.ExistenceProof memory p, bytes memory root) = _bptreeProof();
        ICS23.ProofSpec memory spec = GnoProofSpecs.bptreeSpec(); // before expectRevert: it calls sha256
        p.value = "";
        vm.expectRevert(ICS23.EmptyLeafValue.selector);
        this.verifyExist(spec, root, abi.encode(p), p.key, p.value);
    }
}
