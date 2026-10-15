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

	"github.com/gnolang/gno-eth-ibc/relayer/gnoibc"
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
	gasOut := flag.String("gas-out", "../contracts/test/fixtures/gas.json", "gas benchmark fixtures output file")
	tsOut := flag.String("ts-out", "", "if set, also write vectors for TypeScript ports of gnoibc to this file")
	flag.Parse()
	writeGasFixtures(*gasOut)

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

	// Fixtures carry every precommit unless the options ask for the minimal
	// subset: the tests drop and tamper with signatures themselves.
	addOpts := func(name string, sh *types.SignedHeader, vals *types.ValidatorSet, o gnoibc.HeaderOptions) gnoibc.Header {
		check(vals.VerifyCommit(sh.ChainID, sh.Commit.BlockID, sh.Height, sh.Commit))
		check(sh.ValidateBasic(sh.ChainID))
		hdr := must(gnoibc.EncodeHeader(sh, vals, o))
		fx.Updates[name] = update{
			Msg:                must(gnoibc.PackHeader(hdr)),
			Height:             uint64(sh.Height),
			TimestampNanos:     fmt.Sprint(sh.Time.UnixNano()),
			AppHash:            sh.AppHash,
			NextValidatorsHash: sh.NextValidatorsHash,
			BlockHash:          sh.Hash(),
			NumSignatures:      len(hdr.Commit.Signatures) / gnoibc.SigSize,
		}
		return hdr
	}
	add := func(name string, sh *types.SignedHeader, vals *types.ValidatorSet, trustedHeight int64, trustedVals *types.ValidatorSet, _ bool) gnoibc.Header {
		return addOpts(name, sh, vals, gnoibc.HeaderOptions{TrustedHeight: trustedHeight, TrustedVals: trustedVals, AllSignatures: true})
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
	sh21 := sign(kr, h21, setC, []int{idxA2, idxD, idxE}, 0)
	add("h21Untrusted", sh21, setC, 11, setA, true)

	// --- validator set cache: the client caches A after h11 (next = A) and B
	// after h13 (next = B); these variants leave cached sets out ---
	sh12 := sign(kr, h12, setA, all(setA), 1)
	addOpts("h11NoVals", sh11, setA, gnoibc.HeaderOptions{TrustedHeight: 10, OmitValidators: true, AllSignatures: true})
	addOpts("h12NoVals", sh12, setA, gnoibc.HeaderOptions{TrustedHeight: 11, OmitValidators: true, AllSignatures: true})
	sh13 := sign(kr, h13, setB, []int{0, 1, 3}, 0)
	addOpts("h13NoVals", sh13, setB, gnoibc.HeaderOptions{TrustedHeight: 12, OmitValidators: true, AllSignatures: true})
	addOpts("h20From11CachedTrusted", sh20, setB, gnoibc.HeaderOptions{TrustedHeight: 11, TrustedVals: setA, OmitTrusted: true, AllSignatures: true})
	addOpts("h20From11AllCached", sh20, setB, gnoibc.HeaderOptions{TrustedHeight: 11, TrustedVals: setA, OmitTrusted: true, OmitValidators: true, AllSignatures: true})
	addOpts("h20From11Min", sh20, setB, gnoibc.HeaderOptions{TrustedHeight: 11, TrustedVals: setA})
	addOpts("h21UntrustedCached", sh21, setC, gnoibc.HeaderOptions{TrustedHeight: 11, TrustedVals: setA, OmitTrusted: true, AllSignatures: true})

	// --- encoding vectors from h11 / h12 ---
	for _, l := range gnoibc.HeaderLeaves(h11) {
		fx.Encoding.HeaderLeaves = append(fx.Encoding.HeaderLeaves, l)
	}
	fx.Encoding.HeaderHash = h11.Hash()
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

	if *tsOut != "" {
		v := tsVectors{Source: "github.com/gnolang/gno-eth-ibc fixtures/cmd/genfixtures -ts-out"}
		o := func(th int64, tv *types.ValidatorSet, omitV, omitT, all bool) gnoibc.HeaderOptions {
			return gnoibc.HeaderOptions{TrustedHeight: th, TrustedVals: tv, OmitValidators: omitV, OmitTrusted: omitT, AllSignatures: all}
		}
		v.Headers = []tsHeaderCase{
			newTSHeaderCase("adjacent 3 validators, all signatures, keys", sh11, setA, o(10, setA, false, false, true)),
			newTSHeaderCase("adjacent 3 validators, minimal signers, keys", sh11, setA, o(10, setA, false, false, false)),
			newTSHeaderCase("adjacent, round 1, set change announced, cached set", sh12, setA, o(11, setA, true, false, false)),
			newTSHeaderCase("adjacent 4 validators, one absent precommit", sh13, setB, o(12, setB, false, false, false)),
			newTSHeaderCase("non-adjacent across a set change, both sets sent", sh20, setB, o(11, setA, false, false, false)),
			newTSHeaderCase("non-adjacent across a set change, trusted set cached", sh20, setB, o(11, setA, false, true, false)),
			newTSHeaderCase("non-adjacent across a set change, all cached, all signatures", sh20, setB, o(11, setA, true, true, true)),
			newTSHeaderCase("non-adjacent, same set", sh20, setB, o(13, setB, true, false, false)),
			newTSHeaderCase("trust level unreachable, all signatures", sh21, setC, o(11, setA, false, false, true)),
		}
		for _, pc := range []struct {
			name string
			key  []byte
		}{
			{"packet commitment seq 1", append([]byte(paramPrefix), packetKey(clientID, 1, 1)...)},
			{"packet commitment seq 58 (':' in the key)", append([]byte(paramPrefix), packetKey(clientID, 1, 58)...)},
			{"acknowledgement seq 1", append([]byte(paramPrefix), packetKey(clientID, 3, 1)...)},
			{"absent commitment between two keys", append([]byte(paramPrefix), packetKey(clientID, 1, 3)...)},
			{"absent receipt", append([]byte(paramPrefix), packetKey(clientID, 2, 2)...)},
			{"absent, after every key", []byte("~")},
			{"absent, before every key", []byte("!")},
		} {
			v.Proofs = append(v.Proofs, newTSProofCase(st, pc.name, pc.key))
		}
		writeTSVectors(*tsOut, v)
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
