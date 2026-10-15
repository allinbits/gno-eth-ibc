package gnoibc

import (
	"bytes"
	"crypto/sha256"
	"fmt"
	"math"
	"sort"

	ethcrypto "github.com/ethereum/go-ethereum/crypto"
	"github.com/gnolang/gno/tm2/pkg/amino"
	"github.com/gnolang/gno/tm2/pkg/bft/types"
	"github.com/gnolang/gno/tm2/pkg/crypto/secp256k1"
)

// NoTrustedIndex marks a signature whose signer is not in the trusted set (or
// whose update does not check the trust level).
const NoTrustedIndex = math.MaxUint16

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
	copy(hf.ValidatorsHash[:], h.ValidatorsHash)
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

// HeaderOptions shape an update message.
type HeaderOptions struct {
	// TrustedHeight is the client's consensus state the update verifies from.
	TrustedHeight int64
	// TrustedVals is the next validator set of the trusted height. When the
	// update is non-adjacent and the header's set differs from it, the client
	// checks the trust level over it, and the signers are chosen to meet it.
	// Nil means the header's set is the trusted set.
	TrustedVals *types.ValidatorSet
	// OmitValidators leaves out the header's validator set: the client has
	// it cached (GnoLightClient.isValidatorSetCached).
	OmitValidators bool
	// OmitTrusted leaves out the trusted set: the client has it cached.
	OmitTrusted bool
	// AllSignatures sends every precommit for the block instead of the
	// fewest that meet the thresholds.
	AllSignatures bool
	// TrustLevel defaults to 1/3, the client's default.
	TrustNumerator, TrustDenominator uint64
}

// NeedsTrustCheck reports whether the client will check the trust level for
// a header of height h with validator set vals.
func (o HeaderOptions) NeedsTrustCheck(h int64, vals *types.ValidatorSet) bool {
	return o.TrustedVals != nil && h != o.TrustedHeight+1 && !bytes.Equal(vals.Hash(), o.TrustedVals.Hash())
}

// SelectSigners returns the indices (ascending) of the precommits to send:
// all precommits for the commit's BlockID, or, unless all is set, a minimal
// prefix of them: first by trusted power until more than num/den of the
// trusted set's power signed (when trusted is non-nil), then by power until
// more than 2/3 of vals' power signed. Thresholds are tm2's: strictly more
// than total*2/3 and total*num/den, with integer division.
func SelectSigners(commit *types.Commit, vals, trusted *types.ValidatorSet, num, den uint64, all bool) ([]int, error) {
	var cands []int
	for idx, pc := range commit.Precommits {
		if pc != nil && pc.BlockID.Equals(commit.BlockID) && idx < vals.Size() {
			cands = append(cands, idx)
		}
	}
	if all {
		return cands, nil
	}
	chosen := map[int]bool{}
	var tallied, trustTallied int64
	add := func(idx int) {
		chosen[idx] = true
		v := vals.Validators[idx]
		tallied += v.VotingPower
		if trusted != nil {
			if _, tv := trusted.GetByAddress(v.Address); tv != nil {
				trustTallied += tv.VotingPower
			}
		}
	}
	trustedPower := func(idx int) int64 {
		if trusted == nil {
			return 0
		}
		if _, tv := trusted.GetByAddress(vals.Validators[idx].Address); tv != nil {
			return tv.VotingPower
		}
		return 0
	}
	byDesc := func(key func(int) int64) []int {
		out := append([]int(nil), cands...)
		sort.SliceStable(out, func(a, b int) bool { return key(out[a]) > key(out[b]) })
		return out
	}
	if trusted != nil {
		need := trusted.TotalVotingPower() * int64(num) / int64(den)
		for _, idx := range byDesc(trustedPower) {
			if trustTallied > need {
				break
			}
			if trustedPower(idx) > 0 {
				add(idx)
			}
		}
		if trustTallied <= need {
			return nil, fmt.Errorf("trusted signers hold %d, need more than %d", trustTallied, need)
		}
	}
	need := vals.TotalVotingPower() * 2 / 3
	for _, idx := range byDesc(func(i int) int64 { return vals.Validators[i].VotingPower }) {
		if tallied > need {
			break
		}
		if !chosen[idx] {
			add(idx)
		}
	}
	if tallied <= need {
		return nil, fmt.Errorf("signers hold %d, need more than %d", tallied, need)
	}
	out := make([]int, 0, len(chosen))
	for idx := range chosen {
		out = append(out, idx)
	}
	sort.Ints(out)
	return out, nil
}

// EncodeCommit packs the chosen precommits (indices into vals and the
// commit). trusted, when non-nil, fills in each signer's trusted index.
func EncodeCommit(chainID string, commit *types.Commit, vals, trusted *types.ValidatorSet, signers []int) (Commit, error) {
	var c Commit
	if commit.Round() < 0 || commit.BlockID.PartsHeader.Total < 0 {
		return c, fmt.Errorf("negative round or part set total")
	}
	if vals.Size() >= NoTrustedIndex {
		return c, fmt.Errorf("validator set too large")
	}
	c.Round = uint32(commit.Round())
	c.PartSetTotal = uint32(commit.BlockID.PartsHeader.Total)
	var err error
	if c.PartSetHash, err = to32(commit.BlockID.PartsHeader.Hash); err != nil {
		return c, fmt.Errorf("part set hash: %w", err)
	}
	c.Signatures = make([]byte, 0, len(signers)*SigSize)
	for _, idx := range signers {
		pc := commit.Precommits[idx]
		_, val := vals.GetByIndex(idx)
		if pc == nil || val == nil {
			return c, fmt.Errorf("no precommit or validator at %d", idx)
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
			ValidatorIndex: uint16(idx),
			TrustedIndex:   NoTrustedIndex,
			TimeSeconds:    uint64(pc.Timestamp.Unix()),
			TimeNanos:      uint32(pc.Timestamp.Nanosecond()),
			V:              v,
		}
		copy(cs.R[:], pc.Signature[:32])
		copy(cs.S[:], pc.Signature[32:])
		if trusted != nil {
			if ti, tv := trusted.GetByAddress(val.Address); tv != nil {
				cs.TrustedIndex = uint16(ti)
			}
		}
		c.Signatures = cs.Pack(c.Signatures)
	}
	return c, nil
}

// EncodeHeader builds the updateClient message for sh, signed by vals.
func EncodeHeader(sh *types.SignedHeader, vals *types.ValidatorSet, o HeaderOptions) (Header, error) {
	var h Header
	var err error
	if !bytes.Equal(vals.Hash(), sh.ValidatorsHash) {
		return h, fmt.Errorf("validator set does not match header")
	}
	if o.TrustNumerator == 0 {
		o.TrustNumerator, o.TrustDenominator = 1, 3
	}
	var trustCheck *types.ValidatorSet
	if o.NeedsTrustCheck(sh.Height, vals) {
		trustCheck = o.TrustedVals
	}
	if h.SignedHeader, err = EncodeHeaderFields(sh.Header); err != nil {
		return h, err
	}
	signers, err := SelectSigners(sh.Commit, vals, trustCheck, o.TrustNumerator, o.TrustDenominator, o.AllSignatures)
	if err != nil {
		return h, err
	}
	if h.Commit, err = EncodeCommit(sh.ChainID, sh.Commit, vals, trustCheck, signers); err != nil {
		return h, err
	}
	h.ValidatorSet = []Validator{}
	if !o.OmitValidators {
		if h.ValidatorSet, err = EncodeValidatorSet(vals); err != nil {
			return h, err
		}
	}
	h.TrustedValidators = []Validator{}
	if trustCheck != nil && !o.OmitTrusted {
		if h.TrustedValidators, err = EncodeValidatorSet(trustCheck); err != nil {
			return h, err
		}
	}
	h.TrustedHeight = uint64(o.TrustedHeight)
	return h, nil
}
