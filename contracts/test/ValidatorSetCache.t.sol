// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ILightClientMsgs } from "@eureka/msgs/ILightClientMsgs.sol";

import { GnoLightClient } from "../src/GnoLightClient.sol";
import { IGnoLightClientErrors as Errs } from "../src/errors/IGnoLightClientErrors.sol";
import { IGnoLightClientMsgs as Msgs } from "../src/msgs/IGnoLightClientMsgs.sol";
import { Fixtures } from "./utils/Fixtures.sol";
import { Sigs } from "./utils/Sigs.sol";

/// @notice The validator set cache: A (3 validators) is cached once h11 (next = A) is accepted, B (4) once h13
/// (next = B) is; updates may then omit those sets.
contract ValidatorSetCacheTest is Fixtures {
    GnoLightClient internal client;
    bytes32 internal hashA;
    bytes32 internal hashB;

    function setUp() public {
        _loadFixtures();
        client = _deploy();
        vm.warp(t0Seconds + 120);
        hashA = _header("h11").signedHeader.validatorsHash;
        hashB = _header("h13").signedHeader.validatorsHash;
    }

    function _update(string memory name) internal returns (ILightClientMsgs.UpdateResult) {
        return client.updateClient(_msg(name));
    }

    function _ok(string memory name) internal {
        assertEq(uint8(_update(name)), uint8(ILightClientMsgs.UpdateResult.Update), name);
    }

    function test_cacheMiss_firstSightNeedsKeys() public {
        assertFalse(client.isValidatorSetCached(hashA));
        vm.expectRevert(abi.encodeWithSelector(Errs.ValidatorSetNotCached.selector, hashA));
        _update("h11NoVals");
    }

    function test_cacheHit() public {
        _ok("h11");
        assertTrue(client.isValidatorSetCached(hashA));
        (address[] memory addrs, uint256[] memory powers, uint256 total) = client.getValidatorSet(hashA);
        assertEq(addrs.length, 3);
        assertEq(total, 60);
        assertEq(powers[0] + powers[1] + powers[2], 60);
        _ok("h12NoVals");
        Msgs.ConsensusState memory cs = client.getConsensusState(12);
        assertEq(cs.nextValidatorsHash, hashB);
    }

    function test_cachedEntriesAreTheSuppliedKeys() public {
        _ok("h11");
        (address[] memory addrs,,) = client.getValidatorSet(hashA);
        Msgs.Validator[] memory vals = _header("h11").validatorSet;
        for (uint256 i = 0; i < 3; ++i) {
            assertEq(addrs[i], address(uint160(uint256(keccak256(vals[i].pubKey)))));
        }
    }

    function test_setChange() public {
        _ok("h11");
        _ok("h12"); // announces B; supplies A, which is not B: nothing new cached
        assertFalse(client.isValidatorSetCached(hashB));
        vm.expectRevert(abi.encodeWithSelector(Errs.ValidatorSetNotCached.selector, hashB));
        _update("h13NoVals");
        _ok("h13"); // supplies B, whose next set is B
        assertTrue(client.isValidatorSetCached(hashB));
    }

    function test_nonAdjacent_trustedSetFromCache() public {
        _ok("h11");
        _ok("h20From11CachedTrusted"); // B supplied, A from the cache for the trust check
    }

    function test_nonAdjacent_bothSetsFromCache() public {
        _ok("h11");
        _ok("h12");
        _ok("h13");
        bytes memory m = _msg("h20From11AllCached");
        assertLt(m.length, _msg("h20From11").length / 2);
        _ok("h20From11AllCached");
    }

    function test_nonAdjacent_trustedSetNotCached() public {
        // trusting the initial state (10, next = A), whose set was never supplied
        Msgs.Header memory h = abi.decode(_msg("h20From11CachedTrusted"), (Msgs.Header));
        h.trustedHeight = 10;
        vm.expectRevert(abi.encodeWithSelector(Errs.ValidatorSetNotCached.selector, hashA));
        client.updateClient(abi.encode(h));
    }

    function test_nonAdjacent_cachedTrustNotMet() public {
        _ok("h11");
        vm.expectRevert(abi.encodeWithSelector(Errs.InsufficientTrustedVotingPower.selector, 10, 60));
        _update("h21UntrustedCached");
    }

    function test_minimalSigners() public {
        _ok("h11");
        Msgs.Header memory h = _header("h20From11Min");
        assertLt(h.commit.signatures.length / Sigs.SIZE, 4);
        _ok("h20From11Min");
    }

    // ------------------------------------------------------------ tampering

    function test_tamper_claimAnotherCachedSet() public {
        _ok("h11");
        _ok("h12");
        _ok("h13");
        // B signed h20; claim the header's set is A (also cached): the header hash changes, signatures fail
        Msgs.Header memory h = abi.decode(_msg("h20From11AllCached"), (Msgs.Header));
        h.signedHeader.validatorsHash = hashA;
        vm.expectPartialRevert(Errs.InvalidSignature.selector);
        client.updateClient(abi.encode(h));
    }

    function test_tamper_suppliedSetMustMatchClaimedHash() public {
        Msgs.Header memory h = _header("h11");
        h.validatorSet[0].votingPower += 1;
        vm.expectPartialRevert(Errs.ValidatorSetHashMismatch.selector);
        client.updateClient(abi.encode(h));
        assertFalse(client.isValidatorSetCached(hashA));
    }

    function test_tamper_forgedSetWithItsOwnHashIsNotCached() public {
        // a set with a different power, claimed under its own (recomputed) hash: it is not the trusted next set,
        // so the adjacent update fails (and were it non-adjacent, the header would no longer be the signed one);
        // nothing is cached
        Msgs.Header memory h = _header("h11");
        h.validatorSet[0].votingPower = 1000;
        h.signedHeader.validatorsHash = bytes32(0);
        try client.updateClient(abi.encode(h)) {
            revert("forged update accepted");
        } catch (bytes memory err) {
            bytes32 computed;
            assembly {
                computed := mload(add(err, 68))
            }
            h.signedHeader.validatorsHash = computed;
            h.signedHeader.nextValidatorsHash = computed;
        }
        vm.expectPartialRevert(Errs.ValidatorsHashMismatch.selector);
        client.updateClient(abi.encode(h));
        assertFalse(client.isValidatorSetCached(h.signedHeader.validatorsHash));
    }

    function test_tamper_cachedTrustedIndexMismatch() public {
        _ok("h11");
        Msgs.Header memory h = abi.decode(_msg("h20From11CachedTrusted"), (Msgs.Header));
        Msgs.CommitSig[] memory sigs = Sigs.decode(h.commit.signatures);
        for (uint256 i = 0; i < sigs.length; ++i) {
            if (sigs[i].trustedIndex != type(uint16).max) {
                sigs[i].trustedIndex = (sigs[i].trustedIndex + 1) % 3;
                h.commit.signatures = Sigs.encode(sigs);
                vm.expectRevert(abi.encodeWithSelector(Errs.TrustedSignerMismatch.selector, i));
                client.updateClient(abi.encode(h));
                return;
            }
        }
        revert("no trusted signer in fixture");
    }

    function test_tamper_validatorIndexBeyondCachedSet() public {
        _ok("h11");
        Msgs.Header memory h = abi.decode(_msg("h12NoVals"), (Msgs.Header));
        Msgs.CommitSig[] memory sigs = Sigs.decode(h.commit.signatures);
        sigs[2].validatorIndex = 3;
        h.commit.signatures = Sigs.encode(sigs);
        vm.expectRevert(abi.encodeWithSelector(Errs.ValidatorIndexOutOfRange.selector, 2));
        client.updateClient(abi.encode(h));
    }

    function test_tamper_truncatedSignatures() public {
        Msgs.Header memory h = _header("h11");
        bytes memory sigs = h.commit.signatures;
        assembly {
            mstore(sigs, sub(mload(sigs), 1))
        }
        vm.expectRevert(Errs.InvalidCommitEncoding.selector);
        client.updateClient(abi.encode(h));
    }

    function test_misbehaviourDoesNotCache() public {
        client.misbehaviour(vm.parseJsonBytes(fx, ".misbehaviour"));
        assertFalse(client.isValidatorSetCached(hashA));
    }
}
