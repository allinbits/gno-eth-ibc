// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";

import { ILightClientMsgs } from "@eureka/msgs/ILightClientMsgs.sol";
import { IICS02ClientMsgs } from "@eureka/msgs/IICS02ClientMsgs.sol";
import { ICS24Host } from "@eureka/utils/ICS24Host.sol";

import { GnoLightClient } from "../src/GnoLightClient.sol";
import { IGnoLightClientErrors as Errs } from "../src/errors/IGnoLightClientErrors.sol";
import { IGnoLightClientMsgs as Msgs } from "../src/msgs/IGnoLightClientMsgs.sol";
import { ICS23 } from "../src/lib/ICS23.sol";
import { Fixtures } from "./utils/Fixtures.sol";

contract GnoLightClientTest is Fixtures {
    GnoLightClient internal client;

    uint256 internal constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    function setUp() public {
        _loadFixtures();
        client = _deploy();
        vm.warp(t0Seconds + 120); // two minutes after the trusted header at height 10
    }

    function _update(string memory name) internal returns (ILightClientMsgs.UpdateResult) {
        return client.updateClient(_msg(name));
    }

    function _assertConsensusState(string memory name) internal view {
        uint64 height = uint64(_updateUint(name, "height"));
        Msgs.ConsensusState memory cs = client.getConsensusState(height);
        assertEq(cs.timestamp, _updateUint(name, "timestampNanos"), "timestamp");
        assertEq(cs.appHash, _updateBytes32(name, "appHash"), "appHash");
        assertEq(cs.nextValidatorsHash, _updateBytes32(name, "nextValidatorsHash"), "nextValidatorsHash");
    }

    function _clientState() internal view returns (Msgs.ClientState memory) {
        return abi.decode(client.getClientState(), (Msgs.ClientState));
    }

    /// @dev Index in the validator set of the validator with the given power (fixture powers are distinct in A).
    function _indexOfPower(Msgs.Validator[] memory vals, uint64 power) internal pure returns (uint32) {
        for (uint256 i = 0; i < vals.length; ++i) {
            if (vals[i].votingPower == power) return uint32(i);
        }
        revert("power not found");
    }

    function _keepSignatures(Msgs.Header memory h, uint32[] memory keepIdx) internal pure {
        Msgs.CommitSig[] memory kept = new Msgs.CommitSig[](keepIdx.length);
        uint256 k = 0;
        for (uint256 i = 0; i < h.commit.signatures.length; ++i) {
            for (uint256 j = 0; j < keepIdx.length; ++j) {
                if (h.commit.signatures[i].validatorIndex == keepIdx[j]) kept[k++] = h.commit.signatures[i];
            }
        }
        require(k == keepIdx.length, "missing signature");
        h.commit.signatures = kept;
    }

    // ================================================================ construction

    function test_initialState() public view {
        Msgs.ClientState memory cs = _clientState();
        assertEq(cs.chainId, "test-chain");
        assertEq(cs.latestHeight, 10);
        assertFalse(cs.isFrozen);
        assertEq(client.getConsensusState(10).timestamp, vm.parseJsonUint(fx, ".initial.timestampNanos"));
    }

    function test_constructor_rejectsBadTrustLevel() public {
        Msgs.ClientState memory cs = _initialClientState();
        cs.trustLevel = Msgs.TrustThreshold({ numerator: 1, denominator: 4 });
        vm.expectRevert(Errs.InvalidClientState.selector);
        new GnoLightClient(cs, _initialConsensusState());
        cs.trustLevel = Msgs.TrustThreshold({ numerator: 4, denominator: 3 });
        vm.expectRevert(Errs.InvalidClientState.selector);
        new GnoLightClient(cs, _initialConsensusState());
    }

    // ================================================================ happy paths

    function test_update_adjacent_3validators() public {
        bytes memory m = _msg("h11");
        ILightClientMsgs.UpdateResult res = client.updateClient(m);
        console.log("gas updateClient adjacent, 3 validators / 3 signatures:", vm.lastCallGas().gasTotalUsed);
        assertEq(uint8(res), uint8(ILightClientMsgs.UpdateResult.Update));
        assertEq(_clientState().latestHeight, 11);
        _assertConsensusState("h11");
    }

    function test_update_repeatIsNoOp() public {
        _update("h11");
        assertEq(uint8(_update("h11")), uint8(ILightClientMsgs.UpdateResult.NoOp));
        assertFalse(_clientState().isFrozen);
    }

    function test_update_validatorSetChange_then_4validators() public {
        _update("h11");
        _update("h12"); // round 1, announces the 4-validator set
        _assertConsensusState("h12");
        bytes memory m = _msg("h13");
        ILightClientMsgs.UpdateResult res = client.updateClient(m); // signed by 3 of 4
        console.log("gas updateClient adjacent, 4 validators / 3 signatures:", vm.lastCallGas().gasTotalUsed);
        assertEq(uint8(res), uint8(ILightClientMsgs.UpdateResult.Update));
        _assertConsensusState("h13");
        assertEq(_clientState().latestHeight, 13);
    }

    function test_update_nonAdjacent_trustLevelMet() public {
        _update("h11");
        bytes memory m = _msg("h20From11");
        ILightClientMsgs.UpdateResult res = client.updateClient(m); // A (3 vals) trusted, B (4 vals) signs
        console.log("gas updateClient non-adjacent, 3 trusted + 4 new validators:", vm.lastCallGas().gasTotalUsed);
        assertEq(uint8(res), uint8(ILightClientMsgs.UpdateResult.Update));
        _assertConsensusState("h20From11");
    }

    function test_update_nonAdjacent_sameValidatorSet() public {
        _update("h11");
        _update("h12");
        _update("h13");
        assertEq(uint8(_update("h20From13")), uint8(ILightClientMsgs.UpdateResult.Update));
        assertEq(_clientState().latestHeight, 20);
    }

    function test_update_otherChainAcceptedByItsOwnClient() public {
        Msgs.ClientState memory cs = _initialClientState();
        cs.chainId = "other-chain";
        GnoLightClient other = new GnoLightClient(cs, _initialConsensusState());
        assertEq(uint8(other.updateClient(_msg("h11OtherChain"))), uint8(ILightClientMsgs.UpdateResult.Update));
    }

    // ================================================================ rejected updates

    function test_revert_invalidSignature() public {
        Msgs.Header memory h = _header("h11");
        h.commit.signatures[1].r = bytes32(uint256(h.commit.signatures[1].r) ^ 1);
        vm.expectPartialRevert(Errs.InvalidSignature.selector);
        client.updateClient(abi.encode(h));
    }

    function test_revert_tamperedVoteTimestamp() public {
        Msgs.Header memory h = _header("h11");
        h.commit.signatures[2].timeNanos += 1;
        vm.expectPartialRevert(Errs.InvalidSignature.selector);
        client.updateClient(abi.encode(h));
    }

    function test_revert_tamperedAppHash() public {
        Msgs.Header memory h = _header("h11");
        h.signedHeader.appHash = keccak256("not what was signed");
        vm.expectPartialRevert(Errs.InvalidSignature.selector);
        client.updateClient(abi.encode(h));
    }

    function test_revert_highS() public {
        Msgs.Header memory h = _header("h11");
        Msgs.CommitSig memory s = h.commit.signatures[0];
        // (r, n - s, v ^ 1) is the same ECDSA signature in its malleable form; tm2 rejects it
        s.s = bytes32(SECP256K1_N - uint256(s.s));
        s.v = s.v == 27 ? 28 : 27;
        vm.expectRevert(abi.encodeWithSelector(Errs.InvalidSignatureEncoding.selector, 0));
        client.updateClient(abi.encode(h));
    }

    function test_revert_duplicateSignature() public {
        Msgs.Header memory h = _header("h11");
        h.commit.signatures[1] = h.commit.signatures[0];
        vm.expectRevert(abi.encodeWithSelector(Errs.SignatureIndexOutOfOrder.selector, 1));
        client.updateClient(abi.encode(h));
    }

    function test_revert_insufficientVotingPower() public {
        Msgs.Header memory h = _header("h11");
        // powers 30/20/10: 20 + 10 = 30 of 60
        uint32[] memory keep = new uint32[](2);
        keep[0] = _indexOfPower(h.validatorSet, 20);
        keep[1] = _indexOfPower(h.validatorSet, 10);
        if (keep[0] > keep[1]) (keep[0], keep[1]) = (keep[1], keep[0]);
        _keepSignatures(h, keep);
        vm.expectRevert(abi.encodeWithSelector(Errs.InsufficientVotingPower.selector, 30, 60));
        client.updateClient(abi.encode(h));
    }

    function test_revert_exactlyTwoThirdsIsNotEnough() public {
        Msgs.Header memory h = _header("h11");
        // 30 + 10 = 40 = 2/3 of 60; tm2 needs strictly more
        uint32[] memory keep = new uint32[](2);
        keep[0] = _indexOfPower(h.validatorSet, 30);
        keep[1] = _indexOfPower(h.validatorSet, 10);
        if (keep[0] > keep[1]) (keep[0], keep[1]) = (keep[1], keep[0]);
        _keepSignatures(h, keep);
        vm.expectRevert(abi.encodeWithSelector(Errs.InsufficientVotingPower.selector, 40, 60));
        client.updateClient(abi.encode(h));

        // 30 + 20 = 50 > 40 passes
        h = _header("h11");
        keep[0] = _indexOfPower(h.validatorSet, 30);
        keep[1] = _indexOfPower(h.validatorSet, 20);
        if (keep[0] > keep[1]) (keep[0], keep[1]) = (keep[1], keep[0]);
        _keepSignatures(h, keep);
        assertEq(uint8(client.updateClient(abi.encode(h))), uint8(ILightClientMsgs.UpdateResult.Update));
    }

    function test_revert_wrongChainId() public {
        // a header genuinely signed by the same validators, but for "other-chain"
        vm.expectPartialRevert(Errs.InvalidSignature.selector);
        _update("h11OtherChain");
    }

    function test_revert_trustingPeriodExpired() public {
        vm.warp(t0Seconds + vm.parseJsonUint(fx, ".trustingPeriod") + 1);
        vm.expectPartialRevert(Errs.TrustedConsensusStateExpired.selector);
        _update("h11");
    }

    function test_revert_headerFromTheFuture() public {
        // h11 is 5s after t0; with a 10s drift allowance it is too far ahead at t0 - 6s
        vm.warp(t0Seconds - 6);
        vm.expectPartialRevert(Errs.HeaderTimeInFuture.selector);
        _update("h11");
    }

    function test_revert_nonAdjacent_trustLevelNotMet() public {
        _update("h11");
        // 3 of 4 validators of C sign, but only A2 (10 of A's 60) was trusted: 10 <= 60 * 1/3
        vm.expectRevert(abi.encodeWithSelector(Errs.InsufficientTrustedVotingPower.selector, 10, 60));
        _update("h21Untrusted");
    }

    function test_revert_nonAdjacent_trustedSignaturesDroppedFails() public {
        _update("h11");
        Msgs.Header memory h = _header("h20From11");
        // B = A's three keys (10 each) + D. Keep 3 of 4 signers of B, of which only one is in A.
        // Any 3 of B include two of A, so instead mark the A members as untrusted: trust tally drops.
        for (uint256 i = 0; i < h.commit.signatures.length; ++i) {
            h.commit.signatures[i].trustedIndex = type(uint32).max;
        }
        vm.expectRevert(abi.encodeWithSelector(Errs.InsufficientTrustedVotingPower.selector, 0, 60));
        client.updateClient(abi.encode(h));
    }

    function test_revert_nonAdjacent_wrongTrustedValidators() public {
        _update("h11");
        Msgs.Header memory h = _header("h20From11");
        h.trustedValidators[0].votingPower += 1;
        vm.expectPartialRevert(Errs.TrustedValidatorsHashMismatch.selector);
        client.updateClient(abi.encode(h));
    }

    function test_revert_nonAdjacent_trustedSignerMismatch() public {
        _update("h11");
        Msgs.Header memory h = _header("h20From11");
        // point a signature at another trusted validator
        Msgs.CommitSig memory s = h.commit.signatures[0];
        s.trustedIndex = s.trustedIndex == 0 ? 1 : 0;
        vm.expectRevert(abi.encodeWithSelector(Errs.TrustedSignerMismatch.selector, 0));
        client.updateClient(abi.encode(h));
    }

    function test_revert_validatorSetNotTrusted() public {
        _update("h11");
        // h13 is signed by B, but 11's next validators are A and no trusted set is supplied
        Msgs.Header memory h = _header("h13");
        h.trustedHeight = 11;
        vm.expectPartialRevert(Errs.ValidatorsHashMismatch.selector);
        client.updateClient(abi.encode(h));
    }

    function test_revert_unknownTrustedHeight() public {
        vm.expectRevert(abi.encodeWithSelector(Errs.ConsensusStateNotFound.selector, 11));
        _update("h12");
    }

    function test_revert_belowLatestHeight() public {
        _update("h11");
        _update("h12");
        _update("h13");
        _update("h20From13");
        // a fresh height below the latest is refused
        Msgs.Header memory h = _header("h13");
        h.signedHeader.height = 14;
        vm.expectRevert(abi.encodeWithSelector(Errs.HeightBelowLatest.selector, 14, 20));
        client.updateClient(abi.encode(h));
    }

    // ================================================================ misbehaviour

    function test_misbehaviour_conflictingHeadersFreeze() public {
        bytes memory m = vm.parseJsonBytes(fx, ".misbehaviour");
        client.misbehaviour(m);
        console.log("gas misbehaviour, two 3-validator headers:", vm.lastCallGas().gasTotalUsed);
        assertTrue(_clientState().isFrozen);

        vm.expectRevert(Errs.ClientFrozen.selector);
        _update("h11");
        vm.expectRevert(Errs.ClientFrozen.selector);
        client.misbehaviour(m);
    }

    function test_misbehaviour_frozenClientRejectsProofs() public {
        _update("h11");
        client.misbehaviour(vm.parseJsonBytes(fx, ".misbehaviour"));
        (bytes memory key, bytes memory value, bytes memory proof) = _proofCase("membership", 0);
        vm.expectRevert(Errs.ClientFrozen.selector);
        client.verifyMembership(_membershipMsg(proof, 11, key, value));
    }

    function test_misbehaviour_sameHeaderIsNotMisbehaviour() public {
        Msgs.Header memory h = _header("h11");
        vm.expectRevert(Errs.NotMisbehaviour.selector);
        client.misbehaviour(abi.encode(Msgs.Misbehaviour({ header1: h, header2: h })));
    }

    function test_misbehaviour_invalidHeaderRejected() public {
        Msgs.Misbehaviour memory m = abi.decode(vm.parseJsonBytes(fx, ".misbehaviour"), (Msgs.Misbehaviour));
        m.header2.signedHeader.appHash = keccak256("unsigned");
        vm.expectPartialRevert(Errs.InvalidSignature.selector);
        client.misbehaviour(abi.encode(m));
        assertFalse(_clientState().isFrozen);
    }

    function test_update_conflictingHeaderFreezes() public {
        _update("h11");
        assertEq(uint8(_update("h11Conflict")), uint8(ILightClientMsgs.UpdateResult.Misbehaviour));
        assertTrue(_clientState().isFrozen);
    }

    // ================================================================ membership

    function _path(bytes memory fullKey) internal view returns (bytes[] memory path) {
        path = new bytes[](2);
        path[0] = vm.parseJsonBytes(fx, ".proofs.storeName");
        path[1] = fullKey;
    }

    function _membershipMsg(
        bytes memory proof,
        uint64 height,
        bytes memory key,
        bytes memory value
    )
        internal
        view
        returns (ILightClientMsgs.MsgVerifyMembership memory)
    {
        return ILightClientMsgs.MsgVerifyMembership({
            proof: proof, proofHeight: _height(height), path: _path(key), value: value
        });
    }

    function _nonMembershipMsg(
        bytes memory proof,
        uint64 height,
        bytes memory key
    )
        internal
        view
        returns (ILightClientMsgs.MsgVerifyNonMembership memory)
    {
        return ILightClientMsgs.MsgVerifyNonMembership({ proof: proof, proofHeight: _height(height), path: _path(key) });
    }

    function _height(uint64 h) internal pure returns (IICS02ClientMsgs.Height memory) {
        return IICS02ClientMsgs.Height({ revisionNumber: 0, revisionHeight: h });
    }

    function test_verifyMembership() public {
        _update("h11");
        uint256 want = _updateUint("h11", "timestampNanos") / 1e9;
        for (uint256 i = 0; i < 3; ++i) {
            (bytes memory key, bytes memory value, bytes memory proof) = _proofCase("membership", i);
            ILightClientMsgs.MsgVerifyMembership memory m = _membershipMsg(proof, 11, key, value);
            uint256 ts = client.verifyMembership(m);
            if (i == 0) console.log("gas verifyMembership (bptree + rootmulti proof):", vm.lastCallGas().gasTotalUsed);
            assertEq(ts, want);
        }
    }

    /// @notice The fixture keys are exactly what the ICS26 router asks for: ICS24Host's packet paths appended to
    /// the counterparty merkle prefix ["main", "/pv/vm:gno.land/r/aib/ibc/core:"].
    function test_verifyMembership_routerPaths() public {
        _update("h11");
        bytes[] memory prefix = new bytes[](2);
        prefix[0] = bytes("main");
        prefix[1] = bytes("/pv/vm:gno.land/r/aib/ibc/core:");
        assertEq(prefix[1], vm.parseJsonBytes(fx, ".proofs.keyPrefix"));

        bytes[3] memory ibcPaths = [
            ICS24Host.packetCommitmentPathCalldata("eth-0", 1),
            ICS24Host.packetCommitmentPathCalldata("eth-0", 58),
            ICS24Host.packetAcknowledgementCommitmentPathCalldata("eth-0", 1)
        ];
        for (uint256 i = 0; i < 3; ++i) {
            (bytes memory key, bytes memory value, bytes memory proof) = _proofCase("membership", i);
            bytes[] memory p = new bytes[](2);
            p[0] = prefix[0];
            p[1] = prefix[1];
            bytes[] memory path = ICS24Host.prefixedPath(p, ibcPaths[i]);
            assertEq(path[1], key);
            assertEq(value.length, 32); // raw sha256 commitment, as params.SetBytes stores it
            client.verifyMembership(
                ILightClientMsgs.MsgVerifyMembership({
                    proof: proof, proofHeight: _height(11), path: path, value: value
                })
            );
        }
    }

    function test_verifyMembership_wrongValue() public {
        _update("h11");
        (bytes memory key, bytes memory value, bytes memory proof) = _proofCase("membership", 0);
        value[0] ^= 0x01;
        vm.expectRevert(ICS23.ValueMismatch.selector);
        client.verifyMembership(_membershipMsg(proof, 11, key, value));
    }

    function test_verifyMembership_wrongKey() public {
        _update("h11");
        (bytes memory key, bytes memory value, bytes memory proof) = _proofCase("membership", 0);
        (bytes memory otherKey,,) = _proofCase("membership", 1);
        vm.expectRevert(ICS23.KeyMismatch.selector);
        client.verifyMembership(_membershipMsg(proof, 11, otherKey, value));
        key; // silence
    }

    function test_verifyMembership_tamperedInnerOp() public {
        _update("h11");
        (bytes memory key, bytes memory value, bytes memory proof) = _proofCase("membership", 0);
        Msgs.MembershipProof memory p = abi.decode(proof, (Msgs.MembershipProof));
        ICS23.InnerOp memory op = p.storeProof.path[3];
        if (op.suffix.length > 0) op.suffix[5] ^= 0x01;
        else op.prefix[5] ^= 0x01;
        // the main-store root changes, so it no longer matches the value the root proof commits to
        vm.expectRevert(ICS23.ValueMismatch.selector);
        client.verifyMembership(_membershipMsg(abi.encode(p), 11, key, value));
    }

    function test_verifyMembership_tamperedRootProof() public {
        _update("h11");
        (bytes memory key, bytes memory value, bytes memory proof) = _proofCase("membership", 0);
        Msgs.MembershipProof memory p = abi.decode(proof, (Msgs.MembershipProof));
        p.rootProof.value[0] ^= 0x01; // claims another main-store root
        vm.expectRevert(ICS23.ValueMismatch.selector);
        client.verifyMembership(_membershipMsg(abi.encode(p), 11, key, value));
    }

    function test_verifyMembership_truncatedPathRejected() public {
        _update("h11");
        (bytes memory key, bytes memory value, bytes memory proof) = _proofCase("membership", 0);
        Msgs.MembershipProof memory p = abi.decode(proof, (Msgs.MembershipProof));
        // drop the top four steps: the result is an inner node, not the root
        ICS23.InnerOp[] memory shorter = new ICS23.InnerOp[](p.storeProof.path.length - 4);
        for (uint256 i = 0; i < shorter.length; ++i) {
            shorter[i] = p.storeProof.path[i];
        }
        p.storeProof.path = shorter;
        vm.expectRevert(ICS23.ValueMismatch.selector);
        client.verifyMembership(_membershipMsg(abi.encode(p), 11, key, value));
    }

    function test_verifyMembership_wrongHeight() public {
        _update("h11");
        _update("h12");
        (bytes memory key, bytes memory value, bytes memory proof) = _proofCase("membership", 0);
        vm.expectRevert(ICS23.RootMismatch.selector); // h12's app hash is not the store root
        client.verifyMembership(_membershipMsg(proof, 12, key, value));
        vm.expectRevert(abi.encodeWithSelector(Errs.ConsensusStateNotFound.selector, 99));
        client.verifyMembership(_membershipMsg(proof, 99, key, value));
    }

    function test_verifyMembership_wrongRevision() public {
        _update("h11");
        (bytes memory key, bytes memory value, bytes memory proof) = _proofCase("membership", 0);
        ILightClientMsgs.MsgVerifyMembership memory m = _membershipMsg(proof, 11, key, value);
        m.proofHeight.revisionNumber = 1;
        vm.expectRevert(abi.encodeWithSelector(Errs.InvalidRevisionNumber.selector, 0, 1));
        client.verifyMembership(m);
    }

    function test_verifyMembership_wrongStoreName() public {
        _update("h11");
        (bytes memory key, bytes memory value, bytes memory proof) = _proofCase("membership", 0);
        ILightClientMsgs.MsgVerifyMembership memory m = _membershipMsg(proof, 11, key, value);
        m.path[0] = bytes("base");
        vm.expectRevert(ICS23.KeyMismatch.selector);
        client.verifyMembership(m);
    }

    function test_verifyMembership_expiredClient() public {
        _update("h11");
        (bytes memory key, bytes memory value, bytes memory proof) = _proofCase("membership", 0);
        vm.warp(t0Seconds + 6 + vm.parseJsonUint(fx, ".trustingPeriod")); // h11 time + trusting period
        vm.expectPartialRevert(Errs.ClientExpired.selector);
        client.verifyMembership(_membershipMsg(proof, 11, key, value));
    }

    function test_verifyNonMembership() public {
        _update("h11");
        uint256 want = _updateUint("h11", "timestampNanos") / 1e9;
        // 0: between two commitments, 1: unwritten receipt, 2: after every key, 3: before every key
        for (uint256 i = 0; i < 4; ++i) {
            (bytes memory key,, bytes memory proof) = _proofCase("nonMembership", i);
            ILightClientMsgs.MsgVerifyNonMembership memory m = _nonMembershipMsg(proof, 11, key);
            uint256 ts = client.verifyNonMembership(m);
            console.log("gas verifyNonMembership, case", i, vm.lastCallGas().gasTotalUsed);
            assertEq(ts, want);
        }
        Msgs.NonMembershipProof memory p;
        (,, bytes memory right) = _proofCase("nonMembership", 2);
        p = abi.decode(right, (Msgs.NonMembershipProof));
        assertEq(p.storeProof.right.key.length, 0, "case 2 has no right neighbour");
        (,, bytes memory left) = _proofCase("nonMembership", 3);
        p = abi.decode(left, (Msgs.NonMembershipProof));
        assertEq(p.storeProof.left.key.length, 0, "case 3 has no left neighbour");
    }

    function test_verifyNonMembership_receiptPathFromRouter() public {
        _update("h11");
        (bytes memory key,, bytes memory proof) = _proofCase("nonMembership", 1);
        bytes[] memory prefix = new bytes[](2);
        prefix[0] = bytes("main");
        prefix[1] = bytes("/pv/vm:gno.land/r/aib/ibc/core:");
        bytes[] memory path = ICS24Host.prefixedPath(prefix, ICS24Host.packetReceiptCommitmentPathCalldata("eth-0", 2));
        assertEq(path[1], key);
        client.verifyNonMembership(
            ILightClientMsgs.MsgVerifyNonMembership({ proof: proof, proofHeight: _height(11), path: path })
        );
    }

    function test_verifyNonMembership_existingKeyRejected() public {
        _update("h11");
        // the proof for seq 3 sits between seq 2 and seq 58; claim seq 58 (which exists) is absent
        (,, bytes memory proof) = _proofCase("nonMembership", 0);
        (bytes memory present,,) = _proofCase("membership", 1);
        Msgs.NonMembershipProof memory p = abi.decode(proof, (Msgs.NonMembershipProof));
        assertEq(p.storeProof.right.key, present);
        p.storeProof.key = present;
        vm.expectRevert(ICS23.KeyNotLeftOfRight.selector);
        client.verifyNonMembership(_nonMembershipMsg(abi.encode(p), 11, present));
    }

    function test_verifyNonMembership_droppedNeighbourRejected() public {
        _update("h11");
        (bytes memory key,, bytes memory proof) = _proofCase("nonMembership", 0);
        Msgs.NonMembershipProof memory p = abi.decode(proof, (Msgs.NonMembershipProof));
        delete p.storeProof.right; // pretend nothing follows the left neighbour
        vm.expectRevert(ICS23.LeftNotRightMost.selector);
        client.verifyNonMembership(_nonMembershipMsg(abi.encode(p), 11, key));

        p = abi.decode(proof, (Msgs.NonMembershipProof));
        delete p.storeProof.left;
        vm.expectRevert(ICS23.RightNotLeftMost.selector);
        client.verifyNonMembership(_nonMembershipMsg(abi.encode(p), 11, key));
    }

    function test_verifyNonMembership_nonAdjacentNeighboursRejected() public {
        _update("h11");
        // left neighbour from case 0 (seq 2), right neighbour from case 1 (an unrelated later key)
        (bytes memory key,, bytes memory proof0) = _proofCase("nonMembership", 0);
        (,, bytes memory proof1) = _proofCase("nonMembership", 1);
        Msgs.NonMembershipProof memory p = abi.decode(proof0, (Msgs.NonMembershipProof));
        Msgs.NonMembershipProof memory q = abi.decode(proof1, (Msgs.NonMembershipProof));
        p.storeProof.right = q.storeProof.right;
        vm.expectRevert(ICS23.NotNeighbours.selector);
        client.verifyNonMembership(_nonMembershipMsg(abi.encode(p), 11, key));
    }

    function test_verifyNonMembership_tamperedNeighbour() public {
        _update("h11");
        (bytes memory key,, bytes memory proof) = _proofCase("nonMembership", 0);
        Msgs.NonMembershipProof memory p = abi.decode(proof, (Msgs.NonMembershipProof));
        p.storeProof.left.value[0] ^= 0x01;
        vm.expectRevert(ICS23.RootMismatch.selector);
        client.verifyNonMembership(_nonMembershipMsg(abi.encode(p), 11, key));
    }

    function test_verifyNonMembership_membershipProofRejected() public {
        _update("h11");
        (bytes memory key,, bytes memory proof) = _proofCase("membership", 0);
        vm.expectRevert();
        client.verifyNonMembership(_nonMembershipMsg(proof, 11, key));
    }
}
