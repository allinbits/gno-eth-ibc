// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ILightClient } from "@eureka/interfaces/ILightClient.sol";
import { ILightClientMsgs } from "@eureka/msgs/ILightClientMsgs.sol";

import { IGnoLightClientMsgs as Msgs } from "./msgs/IGnoLightClientMsgs.sol";
import { IGnoLightClientErrors } from "./errors/IGnoLightClientErrors.sol";
import { ICS23 } from "./lib/ICS23.sol";
import { GnoProofSpecs } from "./lib/GnoProofSpecs.sol";
import { Tm2Encoding } from "./lib/Tm2Encoding.sol";
import { Tm2Merkle } from "./lib/Tm2Merkle.sol";

/// @title gno.land light client
/// @notice IBC v2 light client of a tm2 (gno.land) chain whose validators sign with secp256k1. It follows tm2
/// light client verification (adjacent: >2/3 of the header's validators; non-adjacent: additionally more than
/// trustLevel of the trusted next validator set), and verifies gno state with ICS23 proofs: a bptree proof in
/// the "main" store, chained to the rootmulti AppHash with a TendermintSpec proof.
/// @dev Updates are permissionless: everything they store is proven. Consensus states only move forward: a
/// header must be above the latest height unless it repeats a stored one.
contract GnoLightClient is ILightClient, IGnoLightClientErrors {
    /// @notice Lower half of the secp256k1 group order; tm2 rejects signatures with s above it.
    uint256 private constant SECP256K1_HALF_N = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;
    uint32 private constant NO_TRUSTED_INDEX = type(uint32).max;
    uint256 private constant NANOS = 1e9;

    Msgs.ClientState private _clientState;
    mapping(uint64 height => Msgs.ConsensusState) private _consensusStates;

    event ClientUpdated(uint64 indexed height, bytes32 blockHash, bytes32 appHash);
    event Frozen(uint64 indexed height);

    /// @notice Validator set as the contract uses it.
    struct ValSet {
        address[] addrs;
        uint256[] powers;
        uint256 total;
        bytes32 hash;
    }

    /// @notice A header that passed verification.
    struct Verified {
        bytes32 blockHash;
        uint64 height;
        Msgs.ConsensusState consensusState;
    }

    /// @param clientState_ Initial client state; latestHeight must be the height of consensusState_
    /// @param consensusState_ Initial trusted consensus state
    constructor(Msgs.ClientState memory clientState_, Msgs.ConsensusState memory consensusState_) {
        Msgs.TrustThreshold memory tl = clientState_.trustLevel;
        // trust level within [1/3, 1], as in ibc-go's ValidateTrustLevel
        if (
            bytes(clientState_.chainId).length == 0 || clientState_.latestHeight == 0 || clientState_.isFrozen
                || clientState_.trustingPeriod == 0 || tl.denominator == 0 || tl.numerator > tl.denominator
                || uint256(tl.numerator) * 3 < tl.denominator
        ) revert InvalidClientState();
        if (consensusState_.timestamp == 0) revert InvalidConsensusState();
        _clientState = clientState_;
        _consensusStates[clientState_.latestHeight] = consensusState_;
    }

    // ================================================================ views

    /// @inheritdoc ILightClient
    function getClientState() external view returns (bytes memory) {
        return abi.encode(_clientState);
    }

    /// @notice The consensus state stored at height (zero timestamp if none).
    function getConsensusState(uint64 height) external view returns (Msgs.ConsensusState memory) {
        return _consensusStates[height];
    }

    // ================================================================ update

    /// @inheritdoc ILightClient
    /// @dev updateMsg is abi.encode(IGnoLightClientMsgs.Header).
    function updateClient(bytes calldata updateMsg) external returns (ILightClientMsgs.UpdateResult) {
        if (_clientState.isFrozen) revert ClientFrozen();
        Msgs.Header memory header = abi.decode(updateMsg, (Msgs.Header));
        uint64 height = header.signedHeader.height;

        uint64 latest = _clientState.latestHeight;
        Msgs.ConsensusState memory existing = _consensusStates[height];
        if (existing.timestamp != 0) {
            if (_sameConsensusState(existing, header.signedHeader)) return ILightClientMsgs.UpdateResult.NoOp;
        } else if (height < latest) {
            revert HeightBelowLatest(height, latest);
        }

        Verified memory v = _verifyHeader(header, true);

        if (existing.timestamp != 0) {
            // a different, valid header for a height already trusted: a fork
            _freeze(height);
            return ILightClientMsgs.UpdateResult.Misbehaviour;
        }
        if (v.consensusState.timestamp <= _consensusStates[latest].timestamp) {
            // BFT time must increase with height
            _freeze(height);
            return ILightClientMsgs.UpdateResult.Misbehaviour;
        }

        _consensusStates[height] = v.consensusState;
        _clientState.latestHeight = height;
        emit ClientUpdated(height, v.blockHash, v.consensusState.appHash);
        return ILightClientMsgs.UpdateResult.Update;
    }

    /// @inheritdoc ILightClient
    /// @dev misbehaviourMsg is abi.encode(IGnoLightClientMsgs.Misbehaviour). Both headers must verify against
    /// stored consensus states (trusting period, trust level, >2/3 commit); then either they share a height but
    /// not a block hash, or header1 is higher than header2 without being later in time.
    function misbehaviour(bytes calldata misbehaviourMsg) external {
        if (_clientState.isFrozen) revert ClientFrozen();
        Msgs.Misbehaviour memory m = abi.decode(misbehaviourMsg, (Msgs.Misbehaviour));
        Verified memory v1 = _verifyHeader(m.header1, false);
        Verified memory v2 = _verifyHeader(m.header2, false);
        if (v1.height == v2.height) {
            if (v1.blockHash == v2.blockHash) revert NotMisbehaviour();
        } else if (v1.height < v2.height || v1.consensusState.timestamp > v2.consensusState.timestamp) {
            revert NotMisbehaviour();
        }
        _freeze(v1.height);
    }

    function _freeze(uint64 height) private {
        _clientState.isFrozen = true;
        emit Frozen(height);
    }

    function _sameConsensusState(
        Msgs.ConsensusState memory cs,
        Msgs.HeaderFields memory hf
    )
        private
        pure
        returns (bool)
    {
        return
            cs.timestamp == _headerTime(hf) && cs.appHash == hf.appHash
                && cs.nextValidatorsHash == hf.nextValidatorsHash;
    }

    function _headerTime(Msgs.HeaderFields memory hf) private pure returns (uint64) {
        uint256 t = uint256(hf.timeSeconds) * NANOS + hf.timeNanos;
        if (hf.timeNanos >= NANOS || t > type(uint64).max) revert Tm2Encoding.ValueOutOfRange();
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint64(t); // range checked above
    }

    /// @notice tm2 light client verification of one header against a stored consensus state.
    /// @param forUpdate Also require the header to be later than the trusted one and within the clock drift
    /// (misbehaviour evidence is checked without these, as in ibc-go).
    function _verifyHeader(Msgs.Header memory header, bool forUpdate) private view returns (Verified memory v) {
        Msgs.HeaderFields memory hf = header.signedHeader;
        Msgs.ConsensusState memory trusted = _consensusStates[header.trustedHeight];
        if (trusted.timestamp == 0) revert ConsensusStateNotFound(header.trustedHeight);
        if (hf.height <= header.trustedHeight) revert HeightNotAboveTrusted(hf.height, header.trustedHeight);

        uint256 nowNanos = block.timestamp * NANOS;
        uint256 expiry = uint256(trusted.timestamp) + uint256(_clientState.trustingPeriod) * NANOS;
        if (expiry <= nowNanos) revert TrustedConsensusStateExpired(expiry, nowNanos);

        uint64 headerTime = _headerTime(hf);
        if (forUpdate) {
            if (headerTime <= trusted.timestamp) revert HeaderTimeNotAfterTrusted(headerTime, trusted.timestamp);
            uint256 limit = nowNanos + uint256(_clientState.maxClockDrift) * NANOS;
            if (headerTime >= limit) revert HeaderTimeInFuture(headerTime, limit);
        }

        ValSet memory vals = _parseValidatorSet(header.validatorSet);
        bytes memory chainId = bytes(_clientState.chainId);
        v.blockHash = Tm2Encoding.headerHash(hf, chainId, vals.hash);
        v.height = hf.height;
        v.consensusState = Msgs.ConsensusState({
            timestamp: headerTime, appHash: hf.appHash, nextValidatorsHash: hf.nextValidatorsHash
        });

        // Which validator set the trust comes from. Adjacent headers, and non-adjacent ones whose validator
        // set is already the trusted next set, need no second set: >2/3 of it signing implies >1/3.
        ValSet memory trustedVals;
        bool checkTrust = hf.height != header.trustedHeight + 1 && header.trustedValidators.length != 0;
        if (checkTrust) {
            trustedVals = _parseValidatorSet(header.trustedValidators);
            if (trustedVals.hash != trusted.nextValidatorsHash) {
                revert TrustedValidatorsHashMismatch(trusted.nextValidatorsHash, trustedVals.hash);
            }
        } else if (vals.hash != trusted.nextValidatorsHash) {
            revert ValidatorsHashMismatch(trusted.nextValidatorsHash, vals.hash);
        }

        (uint256 tallied, uint256 trustedTallied) =
            _verifyCommit(chainId, hf.height, v.blockHash, header.commit, vals, trustedVals, checkTrust);

        // tm2 VerifyCommit: talliedVotingPower > TotalVotingPower()*2/3
        if (tallied <= vals.total * 2 / 3) revert InsufficientVotingPower(tallied, vals.total);
        if (checkTrust) {
            Msgs.TrustThreshold memory tl = _clientState.trustLevel;
            // atomone 10-gno VerifyLightCommit: tallied > total*numerator/denominator
            if (trustedTallied <= trustedVals.total * tl.numerator / tl.denominator) {
                revert InsufficientTrustedVotingPower(trustedTallied, trustedVals.total);
            }
        }
    }

    /// @notice Verifies each precommit for the block and returns the power behind it, in the header's set and
    /// (if checkTrust) in the trusted set.
    function _verifyCommit(
        bytes memory chainId,
        uint64 height,
        bytes32 blockHash,
        Msgs.Commit memory commit,
        ValSet memory vals,
        ValSet memory trustedVals,
        bool checkTrust
    )
        private
        pure
        returns (uint256 tallied, uint256 trustedTallied)
    {
        (bytes memory pre, bytes memory post) = Tm2Encoding.voteSignBytesParts(
            chainId, height, commit.round, blockHash, commit.partSetTotal, commit.partSetHash
        );
        bool[] memory seenTrusted = new bool[](checkTrust ? trustedVals.addrs.length : 0);
        uint256 nextIndex = 0;
        for (uint256 i = 0; i < commit.signatures.length; ++i) {
            Msgs.CommitSig memory sig = commit.signatures[i];
            if (sig.validatorIndex < nextIndex) revert SignatureIndexOutOfOrder(i);
            if (sig.validatorIndex >= vals.addrs.length) revert ValidatorIndexOutOfRange(i);
            nextIndex = uint256(sig.validatorIndex) + 1;

            address signer = _recover(Tm2Encoding.voteSignBytes(pre, post, sig.timeSeconds, sig.timeNanos), sig, i);
            address expected = vals.addrs[sig.validatorIndex];
            if (signer != expected) revert InvalidSignature(i, signer, expected);
            tallied += vals.powers[sig.validatorIndex];

            if (checkTrust && sig.trustedIndex != NO_TRUSTED_INDEX) {
                if (sig.trustedIndex >= trustedVals.addrs.length) revert TrustedIndexOutOfRange(i);
                if (trustedVals.addrs[sig.trustedIndex] != signer) revert TrustedSignerMismatch(i);
                if (seenTrusted[sig.trustedIndex]) revert DuplicateTrustedSigner(i);
                seenTrusted[sig.trustedIndex] = true;
                trustedTallied += trustedVals.powers[sig.trustedIndex];
            }
        }
    }

    /// @notice ecrecover over sha256(signBytes), as tm2 secp256k1 signs; enforces low-S like tm2's verifier.
    function _recover(
        bytes memory signBytes,
        Msgs.CommitSig memory sig,
        uint256 position
    )
        private
        pure
        returns (address signer)
    {
        if (uint256(sig.s) > SECP256K1_HALF_N || sig.s == 0 || sig.r == 0 || (sig.v != 27 && sig.v != 28)) {
            revert InvalidSignatureEncoding(position);
        }
        signer = ecrecover(sha256(signBytes), sig.v, sig.r, sig.s);
        if (signer == address(0)) revert InvalidSignatureEncoding(position);
    }

    /// @notice Derives addresses and the tm2 ValidatorSet.Hash of a secp256k1 validator set.
    function _parseValidatorSet(Msgs.Validator[] memory validators) private pure returns (ValSet memory vs) {
        uint256 n = validators.length;
        if (n == 0) revert EmptyValidatorSet();
        vs.addrs = new address[](n);
        vs.powers = new uint256[](n);
        bytes32[] memory leaves = new bytes32[](n);
        for (uint256 i = 0; i < n; ++i) {
            uint64 power = validators[i].votingPower;
            if (power == 0 || power > uint64(type(int64).max)) revert InvalidVotingPower();
            (bytes memory compressed, address addr) = Tm2Encoding.parsePubKey(validators[i].pubKey);
            vs.addrs[i] = addr;
            vs.powers[i] = power;
            vs.total += power;
            leaves[i] = Tm2Merkle.leafHash(Tm2Encoding.validatorLeaf(compressed, power));
        }
        vs.hash = Tm2Merkle.rootFromLeafHashes(leaves);
    }

    // ================================================================ membership

    /// @inheritdoc ILightClient
    /// @dev path is [storeName, fullKey] as the ICS26 router builds it from the counterparty merkle prefix
    /// ["main", "/pv/vm:gno.land/r/aib/ibc/core:"]; proof is abi.encode(IGnoLightClientMsgs.MembershipProof).
    function verifyMembership(ILightClientMsgs.MsgVerifyMembership calldata msg_) external view returns (uint256) {
        Msgs.ConsensusState memory cs =
            _provableConsensusState(msg_.proofHeight.revisionNumber, msg_.proofHeight.revisionHeight, msg_.path.length);
        if (msg_.value.length == 0) revert EmptyValue();
        Msgs.MembershipProof memory proof = abi.decode(msg_.proof, (Msgs.MembershipProof));

        bytes memory storeRoot =
            ICS23.existenceRoot(GnoProofSpecs.bptreeSpec(), proof.storeProof, msg_.path[1], msg_.value);
        ICS23.verifyMembership(
            GnoProofSpecs.tendermintSpec(), abi.encodePacked(cs.appHash), proof.rootProof, msg_.path[0], storeRoot
        );
        return cs.timestamp / NANOS;
    }

    /// @inheritdoc ILightClient
    /// @dev proof is abi.encode(IGnoLightClientMsgs.NonMembershipProof).
    function verifyNonMembership(ILightClientMsgs.MsgVerifyNonMembership calldata msg_)
        external
        view
        returns (uint256)
    {
        Msgs.ConsensusState memory cs = _provableConsensusState(
            msg_.proofHeight.revisionNumber, msg_.proofHeight.revisionHeight, msg_.path.length
        );
        Msgs.NonMembershipProof memory proof = abi.decode(msg_.proof, (Msgs.NonMembershipProof));

        bytes memory storeRoot = ICS23.nonExistenceRoot(GnoProofSpecs.bptreeSpec(), proof.storeProof, msg_.path[1]);
        ICS23.verifyMembership(
            GnoProofSpecs.tendermintSpec(), abi.encodePacked(cs.appHash), proof.rootProof, msg_.path[0], storeRoot
        );
        return cs.timestamp / NANOS;
    }

    /// @notice The consensus state to prove against, if the client is active (not frozen, not expired).
    function _provableConsensusState(
        uint64 revisionNumber,
        uint64 height,
        uint256 pathLength
    )
        private
        view
        returns (Msgs.ConsensusState memory cs)
    {
        if (_clientState.isFrozen) revert ClientFrozen();
        uint256 latestTs = _consensusStates[_clientState.latestHeight].timestamp;
        // forge-lint: disable-next-line(block-timestamp)
        if (latestTs + uint256(_clientState.trustingPeriod) * NANOS <= block.timestamp * NANOS) {
            revert ClientExpired(latestTs, block.timestamp * NANOS);
        }
        if (revisionNumber != _clientState.revisionNumber) {
            revert InvalidRevisionNumber(_clientState.revisionNumber, revisionNumber);
        }
        if (pathLength != 2) revert InvalidPathLength(2, pathLength);
        cs = _consensusStates[height];
        if (cs.timestamp == 0) revert ConsensusStateNotFound(height);
    }
}
