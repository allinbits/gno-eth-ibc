package main

import (
	"encoding/json"
	"fmt"
	"os"
	"time"

	"github.com/gnolang/gno-eth-ibc/relayer/gnoibc"
	"github.com/gnolang/gno/tm2/pkg/bft/types"
)

// gasSizes are the validator set sizes of the gas benchmark.
var gasSizes = []int{3, 7, 20, 50, 100}

// gasCase holds, for one set size, a client's initial state (height 10,
// next set S) and update messages. GasScaling.t.sol replays them; "keys"
// means the validator set is supplied, "cached" that it is left out.
type gasCase struct {
	N              int      `json:"n"`
	MinSigners     int      `json:"minSigners"`
	ClientState    hexBytes `json:"clientState"`
	ConsensusState hexBytes `json:"consensusState"`
	// 10 -> 11, keys, every validator signs; 11's next set differs, so
	// nothing is cached (the cost of a header at a set change)
	UncachedAll hexBytes `json:"uncachedAll"`
	// as above with the fewest signers above 2/3
	UncachedMin hexBytes `json:"uncachedMin"`
	// 10 -> 11, keys, fewest signers; 11's next set is S, so S gets cached
	FirstSight hexBytes `json:"firstSight"`
	// 11 -> 12 with S cached, every validator / fewest signers
	CachedAll hexBytes `json:"cachedAll"`
	CachedMin hexBytes `json:"cachedMin"`
	// 11 -> 20, same cached set, fewest signers (no trust check needed)
	NonAdjacentSame hexBytes `json:"nonAdjacentSame"`
	// 11 -> 20 under S' (S with one validator replaced, keys supplied); the
	// trust level is checked over the cached S
	NonAdjacentRotated hexBytes `json:"nonAdjacentRotated"`
}

// writeGasFixtures emits updates for equal-power validator sets of growing
// size, each self-checked with tm2's VerifyCommit.
func writeGasFixtures(path string) {
	var cases []gasCase
	for _, n := range gasSizes {
		kr := keyring{}
		ps := make([]power, n)
		for i := range ps {
			ps[i] = power{newKey(kr, fmt.Sprintf("bench-%d-%d", n, i)), 10}
		}
		vals := valSet(ps...)
		rotated := append([]power{}, ps...)
		rotated[0] = power{newKey(kr, fmt.Sprintf("bench-%d-rotated", n)), 10}
		valsR := valSet(rotated...)
		all := func(vs *types.ValidatorSet) []int {
			out := make([]int, vs.Size())
			for i := range out {
				out[i] = i
			}
			return out
		}
		minSigners := 2*n/3 + 1 // equal power: k*10 > (n*10)*2/3

		h10 := makeHeader(chainID, 10, t0, vals, vals, sha("app 10"))
		h11x := makeHeader(chainID, 11, t0.Add(5*time.Second), vals, valsR, sha("app 11x"))
		h11 := makeHeader(chainID, 11, t0.Add(5*time.Second), vals, vals, sha("app 11"))
		h12 := makeHeader(chainID, 12, t0.Add(10*time.Second), vals, vals, sha("app 12"))
		h20 := makeHeader(chainID, 20, t0.Add(50*time.Second), vals, vals, sha("app 20"))
		h20r := makeHeader(chainID, 20, t0.Add(50*time.Second), valsR, valsR, sha("app 20r"))

		enc := func(sh *types.SignedHeader, vs *types.ValidatorSet, o gnoibc.HeaderOptions) hexBytes {
			check(vs.VerifyCommit(sh.ChainID, sh.Commit.BlockID, sh.Height, sh.Commit))
			hdr := must(gnoibc.EncodeHeader(sh, vs, o))
			if !o.AllSignatures {
				// the chosen subset must convince tm2 too
				check(verifySubset(sh, vs, hdr))
			}
			return must(gnoibc.PackHeader(hdr))
		}
		var app, nv [32]byte
		copy(app[:], h10.AppHash)
		copy(nv[:], h10.NextValidatorsHash)
		sh11x := sign(kr, h11x, vals, all(vals), 0)
		sh11 := sign(kr, h11, vals, all(vals), 0)
		sh12 := sign(kr, h12, vals, all(vals), 0)
		sh20 := sign(kr, h20, vals, all(vals), 0)
		sh20r := sign(kr, h20r, valsR, all(valsR), 0)
		c := gasCase{
			N:          n,
			MinSigners: minSigners,
			ClientState: must(gnoibc.PackClientState(gnoibc.ClientState{
				ChainId: chainID, LatestHeight: 10,
				TrustLevel:     gnoibc.TrustThreshold{Numerator: 1, Denominator: 3},
				TrustingPeriod: trustingPeriod, MaxClockDrift: maxClockDrift,
			})),
			ConsensusState: must(gnoibc.PackConsensusState(gnoibc.ConsensusState{
				Timestamp: uint64(h10.Time.UnixNano()), AppHash: app, NextValidatorsHash: nv,
			})),
			UncachedAll:        enc(sh11x, vals, gnoibc.HeaderOptions{TrustedHeight: 10, AllSignatures: true}),
			UncachedMin:        enc(sh11x, vals, gnoibc.HeaderOptions{TrustedHeight: 10}),
			FirstSight:         enc(sh11, vals, gnoibc.HeaderOptions{TrustedHeight: 10}),
			CachedAll:          enc(sh12, vals, gnoibc.HeaderOptions{TrustedHeight: 11, OmitValidators: true, AllSignatures: true}),
			CachedMin:          enc(sh12, vals, gnoibc.HeaderOptions{TrustedHeight: 11, OmitValidators: true}),
			NonAdjacentSame:    enc(sh20, vals, gnoibc.HeaderOptions{TrustedHeight: 11, OmitValidators: true}),
			NonAdjacentRotated: enc(sh20r, valsR, gnoibc.HeaderOptions{TrustedHeight: 11, TrustedVals: vals, OmitTrusted: true}),
		}
		cases = append(cases, c)
	}
	bz := must(json.MarshalIndent(map[string]any{"cases": cases}, "", "  "))
	check(os.WriteFile(path, append(bz, '\n'), 0o644))
	fmt.Println("wrote", path)
}

// verifySubset checks with tm2 that the precommits kept in hdr alone are a
// valid commit: the others are dropped from a copy of the commit.
func verifySubset(sh *types.SignedHeader, vals *types.ValidatorSet, hdr gnoibc.Header) error {
	kept := map[int]bool{}
	sigs := hdr.Commit.Signatures
	for i := 0; i+gnoibc.SigSize <= len(sigs); i += gnoibc.SigSize {
		kept[int(sigs[i])<<8|int(sigs[i+1])] = true
	}
	pcs := make([]*types.CommitSig, len(sh.Commit.Precommits))
	for i, pc := range sh.Commit.Precommits {
		if kept[i] {
			pcs[i] = pc
		}
	}
	return vals.VerifyCommit(sh.ChainID, sh.Commit.BlockID, sh.Height, types.NewCommit(sh.Commit.BlockID, pcs))
}
