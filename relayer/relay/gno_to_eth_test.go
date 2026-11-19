package relay

import (
	"bytes"
	"context"
	"fmt"
	"math/big"
	"testing"

	"github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/accounts/abi/bind"
	"github.com/ethereum/go-ethereum/common"

	"github.com/gnolang/gno-eth-ibc/relayer/eth"
	"github.com/gnolang/gno-eth-ibc/relayer/gnoibc"
	"github.com/gnolang/gno-eth-ibc/relayer/ibc"
)

// fakeLightClient answers GnoLightClient.getClientState with a packed state.
type fakeLightClient struct{ state []byte }

func (fakeLightClient) CodeAt(context.Context, common.Address, *big.Int) ([]byte, error) {
	return []byte{1}, nil
}

func (f fakeLightClient) CallContract(_ context.Context, call ethereum.CallMsg, _ *big.Int) ([]byte, error) {
	m := eth.LightClientABI.Methods["getClientState"]
	if !bytes.Equal(call.Data, m.ID) {
		return nil, fmt.Errorf("unexpected call %x", call.Data)
	}
	return m.Outputs.Pack(f.state)
}

func TestProofHeightCarriesTheClientRevision(t *testing.T) {
	// test-ibc-1 derives revision 1 for a new client; this one was deployed
	// at revision 7, which its proof heights must carry.
	state, err := gnoibc.PackClientState(gnoibc.ClientState{
		ChainId: "test-ibc-1", RevisionNumber: 7, LatestHeight: 10, TrustLevel: gnoibc.TrustThreshold{Numerator: 1, Denominator: 3},
	})
	if err != nil {
		t.Fatal(err)
	}
	r := &GnoToEth{Eth: &eth.Client{
		LightClient: bind.NewBoundContract(common.Address{1}, eth.LightClientABI, fakeLightClient{state}, nil, nil),
	}}
	h, err := r.proofHeight(context.Background(), 41)
	if err != nil {
		t.Fatal(err)
	}
	if want := (ibc.Height{RevisionNumber: 7, RevisionHeight: 42}); h != want {
		t.Errorf("proof height %+v, want %+v", h, want)
	}
}
