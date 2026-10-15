// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title Gno light client errors
interface IGnoLightClientErrors {
    error InvalidClientState();
    error InvalidConsensusState();
    error ClientFrozen();
    error ClientExpired(uint256 latestTimestamp, uint256 nowTimestamp);
    error ConsensusStateNotFound(uint64 height);
    error InvalidRevisionNumber(uint64 expected, uint64 actual);
    error HeightNotAboveTrusted(uint64 height, uint64 trustedHeight);
    error HeightBelowLatest(uint64 height, uint64 latestHeight);
    error TrustedConsensusStateExpired(uint256 expiry, uint256 nowTimestamp);
    error HeaderTimeNotAfterTrusted(uint256 headerTime, uint256 trustedTime);
    error HeaderTimeInFuture(uint256 headerTime, uint256 limit);
    error EmptyValidatorSet();
    error InvalidVotingPower();
    error ValidatorsHashMismatch(bytes32 expected, bytes32 actual);
    error TrustedValidatorsHashMismatch(bytes32 expected, bytes32 actual);
    error SignatureIndexOutOfOrder(uint256 position);
    error ValidatorIndexOutOfRange(uint256 position);
    error TrustedIndexOutOfRange(uint256 position);
    error DuplicateTrustedSigner(uint256 position);
    error InvalidSignatureEncoding(uint256 position);
    error InvalidSignature(uint256 position, address recovered, address expected);
    error TrustedSignerMismatch(uint256 position);
    error InsufficientVotingPower(uint256 tallied, uint256 total);
    error InsufficientTrustedVotingPower(uint256 tallied, uint256 total);
    error NotMisbehaviour();
    error InvalidPathLength(uint256 expected, uint256 actual);
    error EmptyValue();
}
