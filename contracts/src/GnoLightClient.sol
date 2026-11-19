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
    uint256 private constant NO_TRUSTED_INDEX = type(uint16).max;
    uint256 private constant NANOS = 1e9;
    /// @notice Size of one packed CommitSig (see IGnoLightClientMsgs.Commit).
    uint256 private constant SIG_SIZE = 81;

    Msgs.ClientState private _clientState;
    mapping(uint64 height => Msgs.ConsensusState) private _consensusStates;

    /// @notice Cached validator sets, keyed by their tm2 ValidatorSet.Hash: (size << 128) | totalPower, 0 when
    /// not cached. Entries are written only from validators whose hash the contract recomputed from their keys
    /// and powers, so a cached entry is exactly the set the hash commits to.
    mapping(bytes32 valSetHash => uint256 meta) private _valSetMeta;
    /// @notice (votingPower << 160) | ethereumAddress of each validator, in set order.
    mapping(bytes32 valSetHash => mapping(uint256 index => uint256 entry)) private _valSetEntries;

    /// @notice The live epoch: the (validatorsHash, nextValidatorsHash) pair of the latest accepted header. Before the
    /// first update only the trusted next set is known, and the live set reads as zero.
    bytes32 private _liveValidatorsHash;
    bytes32 private _liveNextValidatorsHash;
    /// @notice Block time at which the latest live transition was accepted (0: none yet). See `quarantineEnd`.
    uint64 private _transitionTime;
    /// @notice How many live transitions were accepted: a transition's identity (two can share a block time).
    uint64 private _transitionCount;

    event ClientUpdated(uint64 indexed height, bytes32 blockHash, bytes32 appHash);
    /// @notice An accepted update was a live transition (ADR pr6375 §7.10): token receives over this client are
    /// quarantined from `transitionTime` for the route's governed duration.
    event LiveTransition(
        uint64 indexed height, bytes32 validatorsHash, bytes32 nextValidatorsHash, uint64 transitionTime
    );
    event Frozen(uint64 indexed height);
    event ValidatorSetCached(bytes32 indexed valSetHash, uint256 size, uint256 totalPower);

    /// @notice A validator set as the contract uses it: supplied in the message (entries in memory) or cached
    /// (entries in storage).
    struct ValSet {
        bytes32 hash;
        uint256 size;
        uint256 total;
        bool cached;
        uint256[] entries; // (power << 160) | address, only when supplied
    }

    /// @notice A header that passed verification.
    struct Verified {
        bytes32 blockHash;
        uint64 height;
        Msgs.ConsensusState consensusState;
        ValSet vals;
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
        _liveNextValidatorsHash = consensusState_.nextValidatorsHash;
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

    /// @notice Whether the validator set with this tm2 hash is cached, i.e. may be omitted from updates.
    function isValidatorSetCached(bytes32 valSetHash) external view returns (bool) {
        return _valSetMeta[valSetHash] != 0;
    }

    /// @notice A cached validator set: Ethereum addresses and powers in set order, and the total power.
    function getValidatorSet(bytes32 valSetHash)
        external
        view
        returns (address[] memory addrs, uint256[] memory powers, uint256 totalPower)
    {
        uint256 meta = _valSetMeta[valSetHash];
        uint256 n = meta >> 128;
        addrs = new address[](n);
        powers = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            (addrs[i], powers[i]) = _unpack(_valSetEntries[valSetHash][i]);
        }
        totalPower = uint128(meta);
    }

    // ================================================================ quarantine (E9)

    /// @notice The live epoch: the validator set and announced next set of the latest accepted header.
    function liveEpoch() external view returns (bytes32 validatorsHash, bytes32 nextValidatorsHash) {
        return (_liveValidatorsHash, _liveNextValidatorsHash);
    }

    /// @notice Block time of the latest accepted live transition, 0 if none.
    function lastTransitionTime() external view returns (uint64) {
        return _transitionTime;
    }

    /// @notice The latest accepted live transition: its number (1, 2, ...; 0 if none) and block time. Receivers tell
    /// transitions apart by number, since two can be accepted at one block time.
    function lastTransition() external view returns (uint64 id, uint64 time) {
        return (_transitionCount, _transitionTime);
    }

    /// @notice When a quarantine of `duration` seconds after the latest live transition ends (0 if none happened).
    /// @dev Transition times only grow, so this is the max over every transition of (its time + duration): each
    /// transition sets its own deadline once, and later headers of the established epoch do not extend it. The
    /// duration is the route's governed setting (GnoICS20Transfer, decision kind 11); 0 disables it.
    function quarantineEnd(uint256 duration) public view returns (uint256) {
        uint256 t = _transitionTime;
        return t == 0 || duration == 0 ? 0 : t + duration;
    }

    /// @notice Whether token receives over this client are quarantined under a `duration`-second quarantine.
    function isQuarantined(uint256 duration) external view returns (bool) {
        // forge-lint: disable-next-line(block-timestamp)
        return block.timestamp < quarantineEnd(duration);
    }

    /// @notice Whether the client is frozen (misbehaviour).
    function isFrozen() external view returns (bool) {
        return _clientState.isFrozen;
    }

    /// @notice Whether the latest consensus state is past the trusting period, so nothing can be proven any more.
    function isExpired() external view returns (bool) {
        uint256 latestTs = _consensusStates[_clientState.latestHeight].timestamp;
        // forge-lint: disable-next-line(block-timestamp)
        return latestTs + uint256(_clientState.trustingPeriod) * NANOS <= block.timestamp * NANOS;
    }

    /// @notice Whether an accepted header is a live transition: it announces a next set other than the live epoch's,
    /// or it is signed by a set that is neither the live set nor the live announced next set (a set the chain never
    /// announced: a > 1/3 skip). The anchor the relayer chose plays no part.
    function _isLiveTransition(Msgs.HeaderFields memory hf) private view returns (bool) {
        bytes32 liveNext = _liveNextValidatorsHash;
        return hf.nextValidatorsHash != liveNext
            || (hf.validatorsHash != _liveValidatorsHash && hf.validatorsHash != liveNext);
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
        if (_isLiveTransition(header.signedHeader)) {
            _transitionTime = uint64(block.timestamp);
            ++_transitionCount;
            emit LiveTransition(
                height,
                header.signedHeader.validatorsHash,
                header.signedHeader.nextValidatorsHash,
                uint64(block.timestamp)
            );
        }
        (_liveValidatorsHash, _liveNextValidatorsHash) =
        (header.signedHeader.validatorsHash, header.signedHeader.nextValidatorsHash);
        // The next header's set is this one's next set; when it is this set, keep it for the updates to come.
        if (!v.vals.cached && v.vals.hash == v.consensusState.nextValidatorsHash) _cacheValSet(v.vals);
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

        // The header's validator set: supplied (and hashed here) or cached under the hash the header claims.
        // Either way the set is the preimage of hf.validatorsHash, which the header hash commits to.
        v.vals = _valSet(header.validatorSet, hf.validatorsHash, false);
        bytes memory chainId = bytes(_clientState.chainId);
        v.blockHash = Tm2Encoding.headerHash(hf, chainId, hf.validatorsHash);
        v.height = hf.height;
        v.consensusState = Msgs.ConsensusState({
            timestamp: headerTime, appHash: hf.appHash, nextValidatorsHash: hf.nextValidatorsHash
        });

        // Adjacent headers must be signed by the trusted next set. Non-adjacent ones signed by that same set
        // need no second check (>2/3 of it implies >1/3); otherwise more than the trust level of the trusted
        // next set must have signed too.
        bool adjacent = hf.height == header.trustedHeight + 1;
        ValSet memory trustedVals;
        bool checkTrust = hf.validatorsHash != trusted.nextValidatorsHash;
        if (checkTrust) {
            if (adjacent) revert ValidatorsHashMismatch(trusted.nextValidatorsHash, hf.validatorsHash);
            trustedVals = _valSet(header.trustedValidators, trusted.nextValidatorsHash, true);
        }

        (uint256 tallied, uint256 trustedTallied) =
            _verifyCommit(chainId, hf.height, v.blockHash, header.commit, v.vals, trustedVals, checkTrust);

        // tm2 VerifyCommit: talliedVotingPower > TotalVotingPower()*2/3
        if (tallied <= v.vals.total * 2 / 3) revert InsufficientVotingPower(tallied, v.vals.total);
        if (checkTrust) {
            Msgs.TrustThreshold memory tl = _clientState.trustLevel;
            // atomone 10-gno VerifyLightCommit: tallied > total*numerator/denominator
            if (trustedTallied <= trustedVals.total * tl.numerator / tl.denominator) {
                revert InsufficientTrustedVotingPower(trustedTallied, trustedVals.total);
            }
        }
    }

    /// @notice Verifies each packed precommit for the block and returns the power behind it, in the header's
    /// set and (if checkTrust) in the trusted set.
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
        view
        returns (uint256 tallied, uint256 trustedTallied)
    {
        bytes memory sigs = commit.signatures;
        if (sigs.length % SIG_SIZE != 0) revert InvalidCommitEncoding();
        Tm2Encoding.VoteBuffer memory buf = Tm2Encoding.newVoteBuffer(
            chainId, height, commit.round, blockHash, commit.partSetTotal, commit.partSetHash
        );
        bool[] memory seenTrusted = new bool[](checkTrust ? trustedVals.size : 0);
        uint256 nextIndex = 0;
        uint256 n = sigs.length / SIG_SIZE;
        for (uint256 i = 0; i < n; ++i) {
            Sig memory sig = _sigAt(sigs, i);
            if (sig.validatorIndex < nextIndex) revert SignatureIndexOutOfOrder(i);
            if (sig.validatorIndex >= vals.size) revert ValidatorIndexOutOfRange(i);
            nextIndex = sig.validatorIndex + 1;

            address signer = _recover(Tm2Encoding.voteSignBytes(buf, sig.timeSeconds, sig.timeNanos), sig, i);
            (address expected, uint256 power) = _entry(vals, sig.validatorIndex);
            if (signer != expected) revert InvalidSignature(i, signer, expected);
            tallied += power;

            if (checkTrust && sig.trustedIndex != NO_TRUSTED_INDEX) {
                if (sig.trustedIndex >= trustedVals.size) revert TrustedIndexOutOfRange(i);
                (address trustedAddr, uint256 trustedPower) = _entry(trustedVals, sig.trustedIndex);
                if (trustedAddr != signer) revert TrustedSignerMismatch(i);
                if (seenTrusted[sig.trustedIndex]) revert DuplicateTrustedSigner(i);
                seenTrusted[sig.trustedIndex] = true;
                trustedTallied += trustedPower;
            }
        }
    }

    /// @notice One precommit of the packed signature list.
    struct Sig {
        uint256 validatorIndex;
        uint256 trustedIndex;
        uint64 timeSeconds;
        uint32 timeNanos;
        bytes32 r;
        bytes32 s;
        uint8 v;
    }

    /// @notice Reads the i-th 81-byte record: validatorIndex u16 | trustedIndex u16 | timeSeconds u64 |
    /// timeNanos u32 | r | s | v u8, big-endian.
    function _sigAt(bytes memory sigs, uint256 i) private pure returns (Sig memory sig) {
        uint256 w;
        bytes32 r;
        bytes32 s;
        uint256 v;
        assembly ("memory-safe") {
            let p := add(add(sigs, 32), mul(i, 81))
            w := mload(p)
            r := mload(add(p, 16))
            s := mload(add(p, 48))
            v := byte(0, mload(add(p, 80)))
        }
        sig.validatorIndex = w >> 240;
        sig.trustedIndex = (w >> 224) & 0xffff;
        sig.timeSeconds = uint64(w >> 160);
        sig.timeNanos = uint32(w >> 128);
        sig.r = r;
        sig.s = s;
        sig.v = uint8(v);
    }

    /// @notice ecrecover over sha256(signBytes), as tm2 secp256k1 signs; enforces low-S like tm2's verifier.
    function _recover(bytes memory signBytes, Sig memory sig, uint256 position) private pure returns (address signer) {
        if (uint256(sig.s) > SECP256K1_HALF_N || sig.s == 0 || sig.r == 0 || (sig.v != 27 && sig.v != 28)) {
            revert InvalidSignatureEncoding(position);
        }
        signer = ecrecover(sha256(signBytes), sig.v, sig.r, sig.s);
        if (signer == address(0)) revert InvalidSignatureEncoding(position);
    }

    /// @notice The validator set with tm2 hash `expected`: parsed from `supplied` (whose recomputed hash must
    /// equal it) or, when nothing is supplied, read from the cache.
    function _valSet(
        Msgs.Validator[] memory supplied,
        bytes32 expected,
        bool trustedSet
    )
        private
        view
        returns (ValSet memory vs)
    {
        if (supplied.length != 0) {
            vs = _parseValidatorSet(supplied);
            if (vs.hash != expected) {
                if (trustedSet) revert TrustedValidatorsHashMismatch(expected, vs.hash);
                revert ValidatorSetHashMismatch(expected, vs.hash);
            }
            return vs;
        }
        uint256 meta = _valSetMeta[expected];
        if (meta == 0) revert ValidatorSetNotCached(expected);
        vs.hash = expected;
        vs.size = meta >> 128;
        vs.total = uint128(meta);
        vs.cached = true;
    }

    function _entry(ValSet memory vs, uint256 i) private view returns (address, uint256) {
        return _unpack(vs.cached ? _valSetEntries[vs.hash][i] : vs.entries[i]);
    }

    function _unpack(uint256 e) private pure returns (address addr, uint256 power) {
        addr = address(uint160(e));
        power = e >> 160;
    }

    function _cacheValSet(ValSet memory vs) private {
        if (_valSetMeta[vs.hash] != 0) return;
        mapping(uint256 => uint256) storage entries = _valSetEntries[vs.hash];
        for (uint256 i = 0; i < vs.size; ++i) {
            entries[i] = vs.entries[i];
        }
        _valSetMeta[vs.hash] = (vs.size << 128) | vs.total;
        emit ValidatorSetCached(vs.hash, vs.size, vs.total);
    }

    /// @notice Derives addresses and the tm2 ValidatorSet.Hash of a secp256k1 validator set.
    function _parseValidatorSet(Msgs.Validator[] memory validators) private pure returns (ValSet memory vs) {
        uint256 n = validators.length;
        if (n > NO_TRUSTED_INDEX) revert ValidatorSetTooLarge();
        vs.size = n;
        vs.entries = new uint256[](n);
        bytes32[] memory leaves = new bytes32[](n);
        for (uint256 i = 0; i < n; ++i) {
            uint64 power = validators[i].votingPower;
            if (power == 0 || power > uint64(type(int64).max)) revert InvalidVotingPower();
            (bytes memory compressed, address addr) = Tm2Encoding.parsePubKey(validators[i].pubKey);
            vs.entries[i] = (uint256(power) << 160) | uint160(addr);
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
