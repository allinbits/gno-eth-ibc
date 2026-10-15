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

type gasCase struct {
	N              int      `json:"n"`
	MinSigners     int      `json:"minSigners"`
	ClientState    hexBytes `json:"clientState"`
	ConsensusState hexBytes `json:"consensusState"`
	// adjacent update 10 -> 11, every validator signs
	AdjacentAll hexBytes `json:"adjacentAll"`
	// adjacent update 10 -> 11, the fewest signers above 2/3 of the power
	AdjacentMin hexBytes `json:"adjacentMin"`
	// non-adjacent 10 -> 20, same set, trusted set supplied: the trust level
	// is checked over it as well (every validator signs)
	NonAdjacentTrusted hexBytes `json:"nonAdjacentTrusted"`
	// non-adjacent 10 -> 20, same set, no trusted set (the client's shortcut)
	NonAdjacentSameSet hexBytes `json:"nonAdjacentSameSet"`
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
		all := make([]int, n)
		for i := range all {
			all[i] = i
		}
		minSigners := 2*n/3 + 1 // equal power: k*10 > (n*10)*2/3
		h10 := makeHeader(chainID, 10, t0, vals, vals, sha("app 10"))
		h11 := makeHeader(chainID, 11, t0.Add(5*time.Second), vals, vals, sha("app 11"))
		h20 := makeHeader(chainID, 20, t0.Add(50*time.Second), vals, vals, sha("app 20"))

		enc := func(sh *types.SignedHeader, trustedHeight int64, trusted *types.ValidatorSet) hexBytes {
			check(vals.VerifyCommit(sh.ChainID, sh.Commit.BlockID, sh.Height, sh.Commit))
			return must(gnoibc.PackHeader(must(gnoibc.EncodeHeader(sh, vals, trustedHeight, trusted))))
		}
		var app, nv [32]byte
		copy(app[:], h10.AppHash)
		copy(nv[:], h10.NextValidatorsHash)
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
			AdjacentAll:        enc(sign(kr, h11, vals, all, 0), 10, nil),
			AdjacentMin:        enc(sign(kr, h11, vals, all[:minSigners], 0), 10, nil),
			NonAdjacentTrusted: enc(sign(kr, h20, vals, all, 0), 10, vals),
			NonAdjacentSameSet: enc(sign(kr, h20, vals, all, 0), 10, nil),
		}
		// fewer signers must not pass in tm2 either
		short := sign(kr, h11, vals, all[:minSigners-1], 0)
		if vals.VerifyCommit(chainID, short.Commit.BlockID, 11, short.Commit) == nil {
			panic(fmt.Sprintf("n=%d: %d signers unexpectedly enough", n, minSigners-1))
		}
		cases = append(cases, c)
	}
	bz := must(json.MarshalIndent(map[string]any{"cases": cases}, "", "  "))
	check(os.WriteFile(path, append(bz, '\n'), 0o644))
	fmt.Println("wrote", path)
}
