// Command genfixtures produces the JSON fixtures consumed by the Foundry
// tests. Every signed header, validator set and store proof is built with
// the real tm2 code from github.com/gnolang/gno, then converted with the
// gnoibc package into the ABI format the Solidity light client reads.
package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/gnolang/gno-eth-ibc/fixtures/gnoibc"
	"github.com/gnolang/gno/tm2/pkg/bft/types"
	"github.com/gnolang/gno/tm2/pkg/crypto"
	"github.com/gnolang/gno/tm2/pkg/crypto/secp256k1"
)

const (
	chainID        = "test-chain"
	otherChainID   = "other-chain"
	trustingPeriod = 14 * 24 * 3600 // seconds
	maxClockDrift  = 10             // seconds
)

var t0 = time.Date(2026, 1, 1, 0, 0, 0, 123456789, time.UTC)

type hexBytes []byte

func (h hexBytes) MarshalJSON() ([]byte, error) {
	return json.Marshal("0x" + hex.EncodeToString(h))
}

type keyring map[crypto.Address]secp256k1.PrivKeySecp256k1

func newKey(kr keyring, name string) crypto.PubKey {
	pk := secp256k1.GenPrivKeySecp256k1([]byte("gno-eth-ibc fixture key " + name))
	kr[pk.PubKey().Address()] = pk
	return pk.PubKey()
}

type power struct {
	pub   crypto.PubKey
	power int64
}

func valSet(ps ...power) *types.ValidatorSet {
	vs := make([]*types.Validator, len(ps))
	for i, p := range ps {
		vs[i] = types.NewValidator(p.pub, p.power)
	}
	return types.NewValidatorSet(vs)
}

func sha(s string) []byte {
	h := sha256.Sum256([]byte(s))
	return h[:]
}

func makeHeader(chain string, height int64, tm time.Time, vals, next *types.ValidatorSet, appHash []byte) *types.Header {
	h := &types.Header{
		Version:            "v1.0.0",
		ChainID:            chain,
		Height:             height,
		Time:               tm,
		NumTxs:             height % 3,
		TotalTxs:           height * 2,
		AppVersion:         "",
		LastBlockID:        types.BlockID{Hash: sha(fmt.Sprint("block", height-1)), PartsHeader: types.PartSetHeader{Total: 1, Hash: sha(fmt.Sprint("parts", height-1))}},
		LastCommitHash:     sha(fmt.Sprint("lastcommit", height)),
		ValidatorsHash:     vals.Hash(),
		NextValidatorsHash: next.Hash(),
		ConsensusHash:      sha("consensus params"),
		AppHash:            appHash,
		LastResultsHash:    sha(fmt.Sprint("results", height)),
		ProposerAddress:    vals.Validators[0].Address,
	}
	if h.NumTxs > 0 {
		h.DataHash = sha(fmt.Sprint("data", height))
	}
	return h
}

// sign builds a commit the way tm2 tests do: one precommit per signer, each
// signed by a mock private validator and carrying its own timestamp. The
// first signer's timestamp has zero nanoseconds, so the amino encoding with
// an omitted nanos field is exercised too.
func sign(kr keyring, h *types.Header, vals *types.ValidatorSet, signers []int, round int) *types.SignedHeader {
	blockID := types.BlockID{Hash: h.Hash(), PartsHeader: types.PartSetHeader{Total: 3, Hash: sha(fmt.Sprint("parts", h.ChainID, h.Height, string(h.AppHash)))}}
	precommits := make([]*types.CommitSig, vals.Size())
	for n, idx := range signers {
		val := vals.Validators[idx]
		ts := h.Time.Add(time.Duration(n+1)*137*time.Millisecond + time.Duration(n*7919))
		if n == 0 {
			ts = time.Unix(h.Time.Unix()+1, 0).UTC()
		}
		vote := &types.Vote{
			Type:             types.PrecommitType,
			Height:           h.Height,
			Round:            round,
			BlockID:          blockID,
			Timestamp:        ts,
			ValidatorAddress: val.Address,
			ValidatorIndex:   idx,
		}
		pv := types.NewMockPVWithPrivKey(kr[val.Address])
		if err := pv.SignVote(h.ChainID, vote); err != nil {
			panic(err)
		}
		cs := types.CommitSig(*vote)
		precommits[idx] = &cs
	}
	return &types.SignedHeader{Header: h, Commit: types.NewCommit(blockID, precommits)}
}

type update struct {
	Msg                hexBytes `json:"msg"`
	Height             uint64   `json:"height"`
	TimestampNanos     string   `json:"timestampNanos"`
	AppHash            hexBytes `json:"appHash"`
	NextValidatorsHash hexBytes `json:"nextValidatorsHash"`
	BlockHash          hexBytes `json:"blockHash"`
	NumSignatures      int      `json:"numSignatures"`
}

type proofCase struct {
	Key   hexBytes `json:"key"`   // full key in the main store (prefix || IBC key)
	Value hexBytes `json:"value"` // empty for non-membership
	Proof hexBytes `json:"proof"`
}

type fixture struct {
	ChainID          string `json:"chainId"`
	TrustingPeriod   uint64 `json:"trustingPeriod"`
	MaxClockDrift    uint64 `json:"maxClockDrift"`
	TrustNumerator   uint64 `json:"trustNumerator"`
	TrustDenominator uint64 `json:"trustDenominator"`
	Initial          struct {
		Height         uint64   `json:"height"`
		TimestampNanos string   `json:"timestampNanos"`
		ClientState    hexBytes `json:"clientState"`
		ConsensusState hexBytes `json:"consensusState"`
	} `json:"initial"`
	Updates      map[string]update `json:"updates"`
	Misbehaviour hexBytes          `json:"misbehaviour"`
	Encoding     struct {
		HeaderLeaves     []hexBytes `json:"headerLeaves"`
		HeaderHash       hexBytes   `json:"headerHash"`
		SignBytes        []hexBytes `json:"signBytes"`
		ValidatorLeaves  []hexBytes `json:"validatorLeaves"`
		ValidatorSetHash hexBytes   `json:"validatorSetHash"`
		Validators4Hash  hexBytes   `json:"validators4Hash"`
	} `json:"encoding"`
	Proofs struct {
		ProofHeight   uint64      `json:"proofHeight"`
		AppHash       hexBytes    `json:"appHash"`
		StoreName     hexBytes    `json:"storeName"`
		KeyPrefix     hexBytes    `json:"keyPrefix"`
		Membership    []proofCase `json:"membership"`
		NonMembership []proofCase `json:"nonMembership"`
	} `json:"proofs"`
}

func must[T any](v T, err error) T {
	if err != nil {
		panic(err)
	}
	return v
}

func check(err error) {
	if err != nil {
		panic(err)
	}
}

func main() {
	out := flag.String("out", "../contracts/test/fixtures/gno.json", "output file")
	flag.Parse()

	kr := keyring{}
	a0, a1, a2 := newKey(kr, "A0"), newKey(kr, "A1"), newKey(kr, "A2")
	d, e, f := newKey(kr, "D"), newKey(kr, "E"), newKey(kr, "F")

	setA := valSet(power{a0, 30}, power{a1, 20}, power{a2, 10})               // 3 validators, total 60
	setB := valSet(power{a0, 10}, power{a1, 10}, power{a2, 10}, power{d, 10}) // 4 validators, A plus D
	setC := valSet(power{a2, 10}, power{d, 10}, power{e, 10}, power{f, 10})   // shares only A2 with A

	// --- packet state committed at the app hash of height 11 ---
	commitment1 := sha("packet commitment 1")
	commitment2 := sha("packet commitment 2")
	commitment58 := sha("packet commitment 58") // big-endian 58 contains ':'
	ack1 := sha("ack 1")
	entries := map[string][]byte{
		string(packetKey(clientID, 1, 1)):  commitment1,
		string(packetKey(clientID, 1, 2)):  commitment2,
		string(packetKey(clientID, 1, 58)): commitment58,
		string(packetKey(clientID, 3, 1)):  ack1,
		string(packetKey(clientID, 2, 1)):  {2},
	}
	st := must(buildStore(entries))

	var fx fixture
	fx.ChainID = chainID
	fx.TrustingPeriod = trustingPeriod
	fx.MaxClockDrift = maxClockDrift
	fx.TrustNumerator, fx.TrustDenominator = 1, 3
	fx.Updates = map[string]update{}

	// --- trusted initial state: height 10 ---
	h10 := makeHeader(chainID, 10, t0, setA, setA, sha("app 10"))
	fx.Initial.Height = 10
	fx.Initial.TimestampNanos = fmt.Sprint(h10.Time.UnixNano())
	fx.Initial.ClientState = must(gnoibc.PackClientState(gnoibc.ClientState{
		ChainId: chainID, RevisionNumber: 0, LatestHeight: 10,
		TrustLevel:     gnoibc.TrustThreshold{Numerator: 1, Denominator: 3},
		TrustingPeriod: trustingPeriod, MaxClockDrift: maxClockDrift,
	}))
	var app10, nv10 [32]byte
	copy(app10[:], h10.AppHash)
	copy(nv10[:], h10.NextValidatorsHash)
	fx.Initial.ConsensusState = must(gnoibc.PackConsensusState(gnoibc.ConsensusState{
		Timestamp: uint64(h10.Time.UnixNano()), AppHash: app10, NextValidatorsHash: nv10,
	}))

	add := func(name string, sh *types.SignedHeader, vals *types.ValidatorSet, trustedHeight int64, trustedVals *types.ValidatorSet, expectValid bool) gnoibc.Header {
		if expectValid {
			check(vals.VerifyCommit(sh.ChainID, sh.Commit.BlockID, sh.Height, sh.Commit))
		}
		check(sh.ValidateBasic(sh.ChainID))
		hdr := must(gnoibc.EncodeHeader(sh, vals, trustedHeight, trustedVals))
		fx.Updates[name] = update{
			Msg:                must(gnoibc.PackHeader(hdr)),
			Height:             uint64(sh.Height),
			TimestampNanos:     fmt.Sprint(sh.Time.UnixNano()),
			AppHash:            sh.AppHash,
			NextValidatorsHash: sh.NextValidatorsHash,
			BlockHash:          sh.Hash(),
			NumSignatures:      len(hdr.Commit.Signatures),
		}
		return hdr
	}

	all := func(vs *types.ValidatorSet) []int {
		idx := make([]int, vs.Size())
		for i := range idx {
			idx[i] = i
		}
		return idx
	}

	// adjacent, 3 validators, app hash = the real store root
	h11 := makeHeader(chainID, 11, t0.Add(5*time.Second), setA, setA, st.appHash)
	sh11 := sign(kr, h11, setA, all(setA), 0)
	hdr11 := add("h11", sh11, setA, 10, nil, true)

	// a conflicting header at the same height, also signed by all of A
	h11b := makeHeader(chainID, 11, t0.Add(5*time.Second), setA, setA, sha("forked app state"))
	sh11b := sign(kr, h11b, setA, all(setA), 0)
	hdr11b := add("h11Conflict", sh11b, setA, 10, nil, true)
	fx.Misbehaviour = must(gnoibc.PackMisbehaviour(gnoibc.Misbehaviour{Header1: hdr11, Header2: hdr11b}))

	// same height and validators, but signed for another chain
	h11x := makeHeader(otherChainID, 11, t0.Add(5*time.Second), setA, setA, st.appHash)
	add("h11OtherChain", sign(kr, h11x, setA, all(setA), 0), setA, 10, nil, true)

	// adjacent, round 1, announces the validator set change A -> B
	h12 := makeHeader(chainID, 12, t0.Add(10*time.Second), setA, setB, sha("app 12"))
	add("h12", sign(kr, h12, setA, all(setA), 1), setA, 11, nil, true)

	// adjacent under the new 4-validator set, one precommit missing
	h13 := makeHeader(chainID, 13, t0.Add(15*time.Second), setB, setB, sha("app 13"))
	add("h13", sign(kr, h13, setB, []int{0, 1, 3}, 0), setB, 12, nil, true)

	// non-adjacent from 11 (next = A) to 20 (vals = B): needs >1/3 of A
	h20 := makeHeader(chainID, 20, t0.Add(50*time.Second), setB, setB, sha("app 20"))
	sh20 := sign(kr, h20, setB, all(setB), 0)
	add("h20From11", sh20, setB, 11, setA, true)
	// the same header skipping from 13, whose next set is already B
	add("h20From13", sh20, setB, 13, nil, true)

	// non-adjacent from 11 to 21 (vals = C): 3/4 of C sign, but of A only A2
	// (10 of 60), so the trust level is not met
	h21 := makeHeader(chainID, 21, t0.Add(55*time.Second), setC, setC, sha("app 21"))
	idxA2, _ := setC.GetByAddress(a2.Address())
	idxD, _ := setC.GetByAddress(d.Address())
	idxE, _ := setC.GetByAddress(e.Address())
	add("h21Untrusted", sign(kr, h21, setC, []int{idxA2, idxD, idxE}, 0), setC, 11, setA, true)

	// --- encoding vectors from h11 / h12 ---
	for _, l := range gnoibc.HeaderLeaves(h11) {
		fx.Encoding.HeaderLeaves = append(fx.Encoding.HeaderLeaves, l)
	}
	fx.Encoding.HeaderHash = h11.Hash()
	sh12 := sign(kr, h12, setA, all(setA), 1)
	for _, sh := range []*types.SignedHeader{sh11, sh12} {
		for i, pc := range sh.Commit.Precommits {
			if pc != nil {
				fx.Encoding.SignBytes = append(fx.Encoding.SignBytes, sh.Commit.VoteSignBytes(sh.ChainID, i))
			}
		}
	}
	for _, v := range setA.Validators {
		fx.Encoding.ValidatorLeaves = append(fx.Encoding.ValidatorLeaves, v.Bytes())
	}
	fx.Encoding.ValidatorSetHash = setA.Hash()
	fx.Encoding.Validators4Hash = setB.Hash()

	// --- store proofs against h11's app hash ---
	fx.Proofs.ProofHeight = 11
	fx.Proofs.AppHash = st.appHash
	fx.Proofs.StoreName = []byte(storeName)
	fx.Proofs.KeyPrefix = []byte(paramPrefix)
	for _, k := range [][]byte{
		packetKey(clientID, 1, 1),
		packetKey(clientID, 1, 58),
		packetKey(clientID, 3, 1),
	} {
		val, ops := must2(st.prove(append([]byte(paramPrefix), k...)))
		if val == nil {
			panic("expected value")
		}
		mp := must(gnoibc.EncodeMembershipProof(ops))
		fx.Proofs.Membership = append(fx.Proofs.Membership, proofCase{Key: append([]byte(paramPrefix), k...), Value: val, Proof: must(gnoibc.PackMembershipProof(mp))})
	}
	for _, full := range [][]byte{
		append([]byte(paramPrefix), packetKey(clientID, 1, 3)...), // between two commitments
		append([]byte(paramPrefix), packetKey(clientID, 2, 2)...), // receipt never written
		[]byte("~"), // after every key in the store (all start with '/')
		[]byte("!"), // before every key in the store
	} {
		val, ops := must2(st.prove(full))
		if val != nil {
			panic("expected absence")
		}
		np := must(gnoibc.EncodeNonMembershipProof(ops))
		fx.Proofs.NonMembership = append(fx.Proofs.NonMembership, proofCase{Key: full, Value: hexBytes{}, Proof: must(gnoibc.PackNonMembershipProof(np))})
	}

	bz := must(json.MarshalIndent(fx, "", "  "))
	check(os.MkdirAll(filepath.Dir(*out), 0o755))
	check(os.WriteFile(*out, append(bz, '\n'), 0o644))
	fmt.Println("wrote", *out)
}

func must2[A, B any](a A, b B, err error) (A, B) {
	if err != nil {
		panic(err)
	}
	return a, b
}
