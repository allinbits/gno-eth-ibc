package relay

import (
	"context"
	"fmt"
	"time"

	"github.com/gnolang/gno/tm2/pkg/bft/types"

	"github.com/gnolang/gno-eth-ibc/relayer/gno"
	"github.com/gnolang/gno-eth-ibc/relayer/gnoibc"
	"github.com/gnolang/gno-eth-ibc/relayer/ibc"
)

// TrustOptions parameterise a new GnoLightClient.
type TrustOptions struct {
	Height         int64 // 0: the latest committed height
	TrustingPeriod time.Duration
	MaxClockDrift  time.Duration
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
	return trustedState(sh, o)
}

// trustedState builds the initial states from a trusted header. The client's
// revision number is the one the chain id carries (ibc.ParseChainID): gno.land
// stamps its own heights with it, and every proof height Ethereum verifies
// must match it.
func trustedState(sh *types.SignedHeader, o TrustOptions) (gnoibc.ClientState, gnoibc.ConsensusState, error) {
	if len(sh.AppHash) != 32 || len(sh.NextValidatorsHash) != 32 {
		return gnoibc.ClientState{}, gnoibc.ConsensusState{}, fmt.Errorf("header %d lacks a 32-byte app or next validators hash", sh.Height)
	}
	cs := gnoibc.ClientState{
		ChainId:        sh.ChainID,
		RevisionNumber: ibc.ParseChainID(sh.ChainID),
		LatestHeight:   uint64(sh.Height),
		TrustLevel:     gnoibc.TrustThreshold{Numerator: 1, Denominator: 3},
		TrustingPeriod: uint64(o.TrustingPeriod / time.Second),
		MaxClockDrift:  uint64(o.MaxClockDrift / time.Second),
	}
	cons := gnoibc.ConsensusState{Timestamp: uint64(sh.Time.UnixNano())}
	copy(cons.AppHash[:], sh.AppHash)
	copy(cons.NextValidatorsHash[:], sh.NextValidatorsHash)
	return cs, cons, nil
}
