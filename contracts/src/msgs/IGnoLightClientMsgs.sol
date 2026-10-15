// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ICS23 } from "../lib/ICS23.sol";

/// @title Gno light client messages
/// @notice ABI structures accepted by GnoLightClient. A relayer builds them from tm2 types; see
/// fixtures/gnoibc for a Go implementation and contracts/README.md for the field-by-field mapping.
interface IGnoLightClientMsgs {
    /// @notice Fraction of the trusted validator set's power that must sign a non-adjacent header.
    struct TrustThreshold {
        uint64 numerator;
        uint64 denominator;
    }

    /// @notice Client state, returned ABI-encoded by getClientState().
    /// @param chainId The gno.land chain ID (tm2 Header.ChainID)
    /// @param revisionNumber The revision every proof height must carry
    /// @param latestHeight The highest height with a stored consensus state
    /// @param trustLevel Trust threshold for non-adjacent updates, within [1/3, 1]
    /// @param trustingPeriod Seconds a consensus state can be used to verify a new header
    /// @param maxClockDrift Seconds a header's time may be ahead of block.timestamp
    /// @param isFrozen Set once misbehaviour has been proven
    struct ClientState {
        string chainId;
        uint64 revisionNumber;
        uint64 latestHeight;
        TrustThreshold trustLevel;
        uint64 trustingPeriod;
        uint64 maxClockDrift;
        bool isFrozen;
    }

    /// @notice Trusted data kept per height.
    /// @param timestamp Header time in unix nanoseconds
    /// @param appHash Header AppHash: the rootmulti store root that proofs verify against
    /// @param nextValidatorsHash Header NextValidatorsHash
    struct ConsensusState {
        uint64 timestamp;
        bytes32 appHash;
        bytes32 nextValidatorsHash;
    }

    /// @notice A validator. tm2 hashes the 33-byte compressed key; the contract derives it from the uncompressed
    /// key, which it also needs for the Ethereum address that ecrecover returns.
    /// @param pubKey Uncompressed secp256k1 public key without the 0x04 tag: X || Y (64 bytes)
    /// @param votingPower Voting power, > 0
    struct Validator {
        bytes pubKey;
        uint64 votingPower;
    }

    /// @notice The tm2 header fields the client reads, plus the Merkle siblings needed to recompute Header.Hash.
    /// @dev The contract amino-encodes ChainID (from the client state), Height, Time, ValidatorsHash (computed from
    /// the supplied validator set), NextValidatorsHash and AppHash itself, so what it reads is what is hashed. The
    /// other ten leaves enter only as hashes of the 16-leaf simple Merkle tree:
    /// leaf 0 (Version), subtree 4..7 (NumTxs, TotalTxs, AppVersion, LastBlockID), subtree 8..9 (LastCommitHash,
    /// DataHash), leaf 12 (ConsensusHash) and subtree 14..15 (LastResultsHash, ProposerAddress).
    struct HeaderFields {
        uint64 height;
        uint64 timeSeconds;
        uint32 timeNanos;
        bytes32 nextValidatorsHash;
        bytes32 appHash;
        bytes32 versionLeafHash;
        bytes32 txsAndLastBlockIDHash;
        bytes32 lastCommitAndDataHash;
        bytes32 consensusLeafHash;
        bytes32 resultsAndProposerHash;
    }

    /// @notice One precommit for the committed BlockID.
    /// @param validatorIndex Index of the signer in Header.validatorSet; strictly increasing across the commit
    /// @param trustedIndex Index of the signer in Header.trustedValidators, or type(uint32).max if absent
    /// @param timeSeconds Vote timestamp, seconds part
    /// @param timeNanos Vote timestamp, nanoseconds part
    /// @param r Signature r
    /// @param s Signature s, must be in the lower half of the curve order
    /// @param v Recovery id, 27 or 28. Not signed: the relayer finds it by trial recovery.
    struct CommitSig {
        uint32 validatorIndex;
        uint32 trustedIndex;
        uint64 timeSeconds;
        uint32 timeNanos;
        bytes32 r;
        bytes32 s;
        uint8 v;
    }

    /// @notice The commit for the header. BlockID.Hash is the header hash, recomputed by the contract.
    struct Commit {
        uint32 round;
        uint32 partSetTotal;
        bytes32 partSetHash;
        CommitSig[] signatures;
    }

    /// @notice The updateClient message: abi.encode(Header).
    /// @param signedHeader The header to trust
    /// @param commit Its commit
    /// @param validatorSet The header's validator set, in tm2 set order; must hash to Header.ValidatorsHash
    /// @param trustedHeight Height of the stored consensus state to verify from
    /// @param trustedValidators Validator set hashing to that consensus state's nextValidatorsHash. Leave empty
    /// when validatorSet itself has that hash (always so for adjacent headers).
    struct Header {
        HeaderFields signedHeader;
        Commit commit;
        Validator[] validatorSet;
        uint64 trustedHeight;
        Validator[] trustedValidators;
    }

    /// @notice The misbehaviour message: abi.encode(Misbehaviour). Two headers that would each pass
    /// verification, either for the same height with different block hashes, or with header1 above header2
    /// in height but not in time.
    struct Misbehaviour {
        Header header1;
        Header header2;
    }

    /// @notice verifyMembership proof: abi.encode(MembershipProof).
    /// @param storeProof ics23:bptree existence proof of the key in the "main" store
    /// @param rootProof ics23:simple (TendermintSpec) existence proof of the main store root in the AppHash
    struct MembershipProof {
        ICS23.ExistenceProof storeProof;
        ICS23.ExistenceProof rootProof;
    }

    /// @notice verifyNonMembership proof: abi.encode(NonMembershipProof).
    struct NonMembershipProof {
        ICS23.NonExistenceProof storeProof;
        ICS23.ExistenceProof rootProof;
    }
}
