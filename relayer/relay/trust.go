package relay

import (
	"context"
	"fmt"
	"time"

	"github.com/gnolang/gno-eth-ibc/relayer/gno"
	"github.com/gnolang/gno-eth-ibc/relayer/gnoibc"
)

// TrustOptions parameterise a new GnoLightClient.
type TrustOptions struct {
	Height         int64 // 0: the latest committed height
	TrustingPeriod time.Duration
	MaxClockDrift  time.Duration
	RevisionNumber uint64
}

// TrustedState reads a gno header and returns GnoLightClient's initial client
// and consensus states for it. The header is trusted as is: take it from a
// node you trust.
func TrustedState(ctx context.Context, g *gno.Client, o TrustOptions) (gnoibc.ClientState, gnoibc.ConsensusState, error) {
	h := o.Height
	if h == 0 {
		latest, err := g.LatestHeight(ctx)
		if err != nil {
			return gnoibc.ClientState{}, gnoibc.ConsensusState{}, err
		}
		h = latest
	}
	sh, err := g.SignedHeader(ctx, h)
	if err != nil {
		return gnoibc.ClientState{}, gnoibc.ConsensusState{}, err
	}
	if len(sh.AppHash) != 32 || len(sh.NextValidatorsHash) != 32 {
		return gnoibc.ClientState{}, gnoibc.ConsensusState{}, fmt.Errorf("header %d lacks a 32-byte app or next validators hash", h)
	}
	cs := gnoibc.ClientState{
		ChainId:        sh.ChainID,
		RevisionNumber: o.RevisionNumber,
		LatestHeight:   uint64(h),
		TrustLevel:     gnoibc.TrustThreshold{Numerator: 1, Denominator: 3},
		TrustingPeriod: uint64(o.TrustingPeriod / time.Second),
		MaxClockDrift:  uint64(o.MaxClockDrift / time.Second),
	}
	cons := gnoibc.ConsensusState{Timestamp: uint64(sh.Time.UnixNano())}
	copy(cons.AppHash[:], sh.AppHash)
	copy(cons.NextValidatorsHash[:], sh.NextValidatorsHash)
	return cs, cons, nil
}
