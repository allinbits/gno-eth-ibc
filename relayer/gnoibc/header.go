package gnoibc

import (
	"bytes"
	"crypto/sha256"
	"fmt"
	"math"

	ethcrypto "github.com/ethereum/go-ethereum/crypto"
	"github.com/gnolang/gno/tm2/pkg/amino"
	"github.com/gnolang/gno/tm2/pkg/bft/types"
	"github.com/gnolang/gno/tm2/pkg/crypto/secp256k1"
)

// NoTrustedIndex marks a signature whose signer is not in the trusted set.
const NoTrustedIndex = math.MaxUint32

// HeaderLeaves returns the 16 amino-encoded leaves that types.Header.Hash
// feeds to merkle.SimpleHashFromByteSlices (same order, same nil rule as
// tm2/pkg/bft/types/encoding_helper.go bytesOrNil).
func HeaderLeaves(h *types.Header) [][]byte {
	return [][]byte{
		bytesOrNil(h.Version),
		bytesOrNil(h.ChainID),
		bytesOrNil(h.Height),
		bytesOrNil(h.Time),
		bytesOrNil(h.NumTxs),
		bytesOrNil(h.TotalTxs),
		bytesOrNil(h.AppVersion),
		bytesOrNil(h.LastBlockID),
		bytesOrNil(h.LastCommitHash),
		bytesOrNil(h.DataHash),
		bytesOrNil(h.ValidatorsHash),
		bytesOrNil(h.NextValidatorsHash),
		bytesOrNil(h.ConsensusHash),
		bytesOrNil(h.AppHash),
		bytesOrNil(h.LastResultsHash),
		bytesOrNil(h.ProposerAddress),
	}
}

func bytesOrNil(item any) []byte {
	if item != nil && !amino.IsTypedNil(item) && !amino.IsEmpty(item) {
		return amino.MustMarshal(item)
	}
	return nil
}

func leafHash(leaf []byte) [32]byte {
	return sha256.Sum256(append([]byte{0}, leaf...))
}

func innerHash(l, r [32]byte) [32]byte {
	return sha256.Sum256(append(append([]byte{1}, l[:]...), r[:]...))
}

func to32(b []byte) ([32]byte, error) {
	var out [32]byte
	if len(b) != 32 {
		return out, fmt.Errorf("expected 32 bytes, got %d", len(b))
	}
	copy(out[:], b)
	return out, nil
}

// EncodeHeaderFields extracts the fields the contract needs plus the five
// sibling hashes it cannot recompute, and checks the result reproduces
// h.Hash().
func EncodeHeaderFields(h *types.Header) (HeaderFields, error) {
	var hf HeaderFields
	if h.Height <= 0 || h.Time.Unix() <= 0 {
		return hf, fmt.Errorf("height and time must be positive")
	}
	l := HeaderLeaves(h)
	var lh [16][32]byte
	for i := range l {
		lh[i] = leafHash(l[i])
	}
	var err error
	if hf.NextValidatorsHash, err = to32(h.NextValidatorsHash); err != nil {
		return hf, fmt.Errorf("next validators hash: %w", err)
	}
	if hf.AppHash, err = to32(h.AppHash); err != nil {
		return hf, fmt.Errorf("app hash: %w", err)
	}
	if len(h.ValidatorsHash) != 32 {
		return hf, fmt.Errorf("validators hash must be 32 bytes")
	}
	hf.Height = uint64(h.Height)
	hf.TimeSeconds = uint64(h.Time.Unix())
	hf.TimeNanos = uint32(h.Time.Nanosecond())
	hf.VersionLeafHash = lh[0]
	hf.TxsAndLastBlockIDHash = innerHash(innerHash(lh[4], lh[5]), innerHash(lh[6], lh[7]))
	hf.LastCommitAndDataHash = innerHash(lh[8], lh[9])
	hf.ConsensusLeafHash = lh[12]
	hf.ResultsAndProposerHash = innerHash(lh[14], lh[15])

	full := innerHash(
		innerHash(
			innerHash(innerHash(lh[0], lh[1]), innerHash(lh[2], lh[3])),
			hf.TxsAndLastBlockIDHash,
		),
		innerHash(
			innerHash(hf.LastCommitAndDataHash, innerHash(lh[10], lh[11])),
			innerHash(innerHash(lh[12], lh[13]), hf.ResultsAndProposerHash),
		),
	)
	if !bytes.Equal(full[:], h.Hash()) {
		return hf, fmt.Errorf("sibling reconstruction %X does not match header hash %X", full, h.Hash())
	}
	return hf, nil
}

// EncodeValidator returns the uncompressed key the contract needs.
func EncodeValidator(v *types.Validator) (Validator, error) {
	pk, ok := v.PubKey.(secp256k1.PubKeySecp256k1)
	if !ok {
		return Validator{}, fmt.Errorf("validator %s: only secp256k1 keys are supported, got %T", v.Address, v.PubKey)
	}
	pub, err := ethcrypto.DecompressPubkey(pk[:])
	if err != nil {
		return Validator{}, err
	}
	if v.VotingPower <= 0 {
		return Validator{}, fmt.Errorf("validator %s: non-positive power", v.Address)
	}
	return Validator{PubKey: ethcrypto.FromECDSAPub(pub)[1:], VotingPower: uint64(v.VotingPower)}, nil
}

func EncodeValidatorSet(vals *types.ValidatorSet) ([]Validator, error) {
	if vals == nil {
		return nil, nil
	}
	out := make([]Validator, len(vals.Validators))
	for i, v := range vals.Validators {
		ev, err := EncodeValidator(v)
		if err != nil {
			return nil, err
		}
		out[i] = ev
	}
	return out, nil
}

// RecoveryID finds v in {27, 28} such that ecrecover(digest, v, r, s) is the
// given compressed secp256k1 key. tm2 signatures carry no recovery id.
func RecoveryID(digest []byte, sig []byte, pk secp256k1.PubKeySecp256k1) (uint8, error) {
	if len(sig) != 64 {
		return 0, fmt.Errorf("signature must be 64 bytes")
	}
	for rec := byte(0); rec < 2; rec++ {
		pub, err := ethcrypto.SigToPub(digest, append(append([]byte{}, sig...), rec))
		if err != nil {
			continue
		}
		if bytes.Equal(ethcrypto.CompressPubkey(pub), pk[:]) {
			return 27 + rec, nil
		}
	}
	return 0, fmt.Errorf("signature does not recover to the validator key")
}

// EncodeCommit converts the precommits for the commit's BlockID. Absent
// precommits and precommits for another BlockID (nil votes) are dropped: the
// contract only counts power for the committed block, so omitting them only
// lowers the tally.
func EncodeCommit(chainID string, commit *types.Commit, vals, trustedVals *types.ValidatorSet) (Commit, error) {
	var c Commit
	if commit.Round() < 0 || commit.BlockID.PartsHeader.Total < 0 {
		return c, fmt.Errorf("negative round or part set total")
	}
	c.Round = uint32(commit.Round())
	c.PartSetTotal = uint32(commit.BlockID.PartsHeader.Total)
	var err error
	if c.PartSetHash, err = to32(commit.BlockID.PartsHeader.Hash); err != nil {
		return c, fmt.Errorf("part set hash: %w", err)
	}
	for idx, pc := range commit.Precommits {
		if pc == nil || !pc.BlockID.Equals(commit.BlockID) {
			continue
		}
		_, val := vals.GetByIndex(idx)
		if val == nil {
			return c, fmt.Errorf("precommit %d has no validator", idx)
		}
		pk, ok := val.PubKey.(secp256k1.PubKeySecp256k1)
		if !ok {
			return c, fmt.Errorf("validator %d is not secp256k1", idx)
		}
		digest := sha256.Sum256(commit.VoteSignBytes(chainID, idx))
		v, err := RecoveryID(digest[:], pc.Signature, pk)
		if err != nil {
			return c, fmt.Errorf("precommit %d: %w", idx, err)
		}
		cs := CommitSig{
			ValidatorIndex: uint32(idx),
			TrustedIndex:   NoTrustedIndex,
			TimeSeconds:    uint64(pc.Timestamp.Unix()),
			TimeNanos:      uint32(pc.Timestamp.Nanosecond()),
			V:              v,
		}
		copy(cs.R[:], pc.Signature[:32])
		copy(cs.S[:], pc.Signature[32:])
		if trustedVals != nil {
			if ti, tv := trustedVals.GetByAddress(val.Address); tv != nil {
				cs.TrustedIndex = uint32(ti)
			}
		}
		c.Signatures = append(c.Signatures, cs)
	}
	return c, nil
}

// EncodeHeader builds the updateClient message. trustedVals must be the
// validator set whose hash is the NextValidatorsHash of the consensus state
// at trustedHeight. Pass nil when header.ValidatorsHash equals that hash
// (always the case for adjacent headers): the contract then uses vals.
func EncodeHeader(sh *types.SignedHeader, vals *types.ValidatorSet, trustedHeight int64, trustedVals *types.ValidatorSet) (Header, error) {
	var h Header
	var err error
	if !bytes.Equal(vals.Hash(), sh.ValidatorsHash) {
		return h, fmt.Errorf("validator set does not match header")
	}
	if h.SignedHeader, err = EncodeHeaderFields(sh.Header); err != nil {
		return h, err
	}
	if h.Commit, err = EncodeCommit(sh.ChainID, sh.Commit, vals, trustedVals); err != nil {
		return h, err
	}
	if h.ValidatorSet, err = EncodeValidatorSet(vals); err != nil {
		return h, err
	}
	if h.TrustedValidators, err = EncodeValidatorSet(trustedVals); err != nil {
		return h, err
	}
	if h.TrustedValidators == nil {
		h.TrustedValidators = []Validator{}
	}
	h.TrustedHeight = uint64(trustedHeight)
	return h, nil
}
