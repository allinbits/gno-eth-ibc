package main

import (
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"time"

	"github.com/gnolang/gno-eth-ibc/relayer/gnoibc"
	"github.com/gnolang/gno/tm2/pkg/bft/types"
	"github.com/gnolang/gno/tm2/pkg/crypto/merkle"
	"github.com/gnolang/gno/tm2/pkg/crypto/secp256k1"
)

// Vectors for TypeScript ports of gnoibc (allinbits/ibc-v2-ts-relayer's
// Ethereum host): inputs in the shape of the ibc.lightclients.gno.v1 protobuf
// objects the TS gno client builds from RPC, and the ABI bytes gnoibc encodes
// from them. Byte strings are hex, 64-bit integers decimal strings.

type tsTimestamp struct {
	Seconds string `json:"seconds"`
	Nanos   int    `json:"nanos"`
}

type tsPartSetHeader struct {
	Total string `json:"total"`
	Hash  string `json:"hash"`
}

type tsBlockID struct {
	Hash        string          `json:"hash"`
	PartsHeader tsPartSetHeader `json:"partsHeader"`
}

type tsGnoHeader struct {
	Version            string      `json:"version"`
	ChainID            string      `json:"chainId"`
	Height             string      `json:"height"`
	Time               tsTimestamp `json:"time"`
	NumTxs             string      `json:"numTxs"`
	TotalTxs           string      `json:"totalTxs"`
	AppVersion         string      `json:"appVersion"`
	LastBlockID        tsBlockID   `json:"lastBlockId"`
	LastCommitHash     string      `json:"lastCommitHash"`
	DataHash           string      `json:"dataHash"`
	ValidatorsHash     string      `json:"validatorsHash"`
	NextValidatorsHash string      `json:"nextValidatorsHash"`
	ConsensusHash      string      `json:"consensusHash"`
	AppHash            string      `json:"appHash"`
	LastResultsHash    string      `json:"lastResultsHash"`
	ProposerAddress    string      `json:"proposerAddress"`
}

// tsCommitSig is empty for an absent precommit, as the TS gno client emits.
type tsCommitSig struct {
	Type             int          `json:"type,omitempty"`
	Height           string       `json:"height,omitempty"`
	Round            string       `json:"round,omitempty"`
	BlockID          *tsBlockID   `json:"blockId,omitempty"`
	Timestamp        *tsTimestamp `json:"timestamp,omitempty"`
	ValidatorAddress string       `json:"validatorAddress,omitempty"`
	ValidatorIndex   string       `json:"validatorIndex,omitempty"`
	Signature        string       `json:"signature,omitempty"`
}

type tsValidator struct {
	Address     string            `json:"address"`
	PubKey      map[string]string `json:"pubKey"`
	VotingPower string            `json:"votingPower"`
}

type tsValidatorSet struct {
	Validators []tsValidator `json:"validators"`
}

type tsHeight struct {
	RevisionNumber string `json:"revisionNumber"`
	RevisionHeight string `json:"revisionHeight"`
}

type tsHeader struct {
	SignedHeader struct {
		Header tsGnoHeader `json:"header"`
		Commit struct {
			BlockID    tsBlockID     `json:"blockId"`
			Precommits []tsCommitSig `json:"precommits"`
		} `json:"commit"`
	} `json:"signedHeader"`
	ValidatorSet      tsValidatorSet  `json:"validatorSet"`
	TrustedHeight     tsHeight        `json:"trustedHeight"`
	TrustedValidators *tsValidatorSet `json:"trustedValidators,omitempty"`
}

type tsOptions struct {
	OmitValidators bool `json:"omitValidators"`
	OmitTrusted    bool `json:"omitTrusted"`
	AllSignatures  bool `json:"allSignatures"`
}

type tsHeaderCase struct {
	Name           string    `json:"name"`
	Header         tsHeader  `json:"header"`
	Options        tsOptions `json:"options"`
	ValidatorsHash string    `json:"validatorsHash"`
	BlockHash      string    `json:"blockHash"`
	Expected       string    `json:"expected"` // abi.encode(Header)
}

type tsProofCase struct {
	Name        string `json:"name"`
	Membership  bool   `json:"membership"`
	Key         string `json:"key"`
	Value       string `json:"value"`
	MerkleProof string `json:"merkleProof"` // ibc.core.commitment.v1.MerkleProof, as convertProofsToIcs23 builds it
	Expected    string `json:"expected"`    // abi.encode(MembershipProof | NonMembershipProof)
}

type tsVectors struct {
	Source  string         `json:"source"`
	Headers []tsHeaderCase `json:"headers"`
	Proofs  []tsProofCase  `json:"proofs"`
}

func hx(b []byte) string { return hex.EncodeToString(b) }

func tsTime(t time.Time) tsTimestamp {
	return tsTimestamp{Seconds: fmt.Sprint(t.Unix()), Nanos: t.Nanosecond()}
}

func tsBID(b types.BlockID) tsBlockID {
	return tsBlockID{Hash: hx(b.Hash), PartsHeader: tsPartSetHeader{Total: fmt.Sprint(b.PartsHeader.Total), Hash: hx(b.PartsHeader.Hash)}}
}

func tsVals(vs *types.ValidatorSet) tsValidatorSet {
	out := tsValidatorSet{Validators: []tsValidator{}}
	for _, v := range vs.Validators {
		pk := v.PubKey.(secp256k1.PubKeySecp256k1)
		out.Validators = append(out.Validators, tsValidator{
			Address: v.Address.String(), PubKey: map[string]string{"secp256k1": hx(pk[:])}, VotingPower: fmt.Sprint(v.VotingPower),
		})
	}
	return out
}

func tsHeaderOf(sh *types.SignedHeader, vals *types.ValidatorSet, o gnoibc.HeaderOptions) tsHeader {
	h := sh.Header
	var out tsHeader
	out.SignedHeader.Header = tsGnoHeader{
		Version: h.Version, ChainID: h.ChainID, Height: fmt.Sprint(h.Height), Time: tsTime(h.Time),
		NumTxs: fmt.Sprint(h.NumTxs), TotalTxs: fmt.Sprint(h.TotalTxs), AppVersion: h.AppVersion,
		LastBlockID: tsBID(h.LastBlockID), LastCommitHash: hx(h.LastCommitHash), DataHash: hx(h.DataHash),
		ValidatorsHash: hx(h.ValidatorsHash), NextValidatorsHash: hx(h.NextValidatorsHash),
		ConsensusHash: hx(h.ConsensusHash), AppHash: hx(h.AppHash), LastResultsHash: hx(h.LastResultsHash),
		ProposerAddress: h.ProposerAddress.String(),
	}
	out.SignedHeader.Commit.BlockID = tsBID(sh.Commit.BlockID)
	for _, pc := range sh.Commit.Precommits {
		if pc == nil {
			out.SignedHeader.Commit.Precommits = append(out.SignedHeader.Commit.Precommits, tsCommitSig{})
			continue
		}
		bid := tsBID(pc.BlockID)
		ts := tsTime(pc.Timestamp)
		out.SignedHeader.Commit.Precommits = append(out.SignedHeader.Commit.Precommits, tsCommitSig{
			Type: int(pc.Type), Height: fmt.Sprint(pc.Height), Round: fmt.Sprint(pc.Round), BlockID: &bid,
			Timestamp: &ts, ValidatorAddress: pc.ValidatorAddress.String(), ValidatorIndex: fmt.Sprint(pc.ValidatorIndex),
			Signature: hx(pc.Signature),
		})
	}
	out.ValidatorSet = tsVals(vals)
	out.TrustedHeight = tsHeight{RevisionNumber: "0", RevisionHeight: fmt.Sprint(o.TrustedHeight)}
	if o.TrustedVals != nil {
		tv := tsVals(o.TrustedVals)
		out.TrustedValidators = &tv
	}
	return out
}

func newTSHeaderCase(name string, sh *types.SignedHeader, vals *types.ValidatorSet, o gnoibc.HeaderOptions) tsHeaderCase {
	hdr := must(gnoibc.EncodeHeader(sh, vals, o))
	return tsHeaderCase{
		Name: name, Header: tsHeaderOf(sh, vals, o),
		Options:        tsOptions{OmitValidators: o.OmitValidators, OmitTrusted: o.OmitTrusted, AllSignatures: o.AllSignatures},
		ValidatorsHash: hx(vals.Hash()), BlockHash: hx(sh.Hash()),
		Expected: hx(must(gnoibc.PackHeader(hdr))),
	}
}

// merkleProofBytes is ibc.core.commitment.v1.MerkleProof{proofs: ops' CommitmentProofs}.
func merkleProofBytes(ops []merkle.ProofOp) []byte {
	var out []byte
	for _, op := range ops {
		out = append(out, 0x0a)
		out = appendUvarint(out, uint64(len(op.Data)))
		out = append(out, op.Data...)
	}
	return out
}

func appendUvarint(b []byte, v uint64) []byte {
	for v >= 0x80 {
		b = append(b, byte(v)|0x80)
		v >>= 7
	}
	return append(b, byte(v))
}

func newTSProofCase(st *gnoStore, name string, key []byte) tsProofCase {
	val, ops := must2(st.prove(key))
	c := tsProofCase{Name: name, Membership: val != nil, Key: hx(key), Value: hx(val), MerkleProof: hx(merkleProofBytes(ops))}
	if val != nil {
		c.Expected = hx(must(gnoibc.PackMembershipProof(must(gnoibc.EncodeMembershipProof(ops)))))
	} else {
		c.Expected = hx(must(gnoibc.PackNonMembershipProof(must(gnoibc.EncodeNonMembershipProof(ops)))))
	}
	return c
}

func writeTSVectors(path string, v tsVectors) {
	bz := must(json.MarshalIndent(v, "", "  "))
	check(os.WriteFile(path, append(bz, '\n'), 0o644))
	fmt.Println("wrote", path)
}
