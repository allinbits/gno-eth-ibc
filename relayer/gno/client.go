// Package gno is the relayer's gno.land side: RPC queries (signed headers,
// validator sets, store proofs, events) and transaction submission through
// gnoclient.
package gno

import (
	"bytes"
	"context"
	"fmt"
	"time"

	"github.com/gnolang/gno/gno.land/pkg/gnoclient"
	"github.com/gnolang/gno/gno.land/pkg/sdk/vm"
	rpcclient "github.com/gnolang/gno/tm2/pkg/bft/rpc/client"
	ctypes "github.com/gnolang/gno/tm2/pkg/bft/rpc/core/types"
	"github.com/gnolang/gno/tm2/pkg/bft/types"
	"github.com/gnolang/gno/tm2/pkg/crypto"
	"github.com/gnolang/gno/tm2/pkg/crypto/merkle"
	"github.com/gnolang/gno/tm2/pkg/std"
)

// CoreRealm is the IBC core realm; its packet state lives under the params
// prefix "/pv/vm:<CoreRealm>:" of the "main" store.
const (
	CoreRealm     = "gno.land/r/aib/ibc/core"
	StoreName     = "main"
	ParamsPrefix  = "/pv/vm:" + CoreRealm + ":"
	storeQueryFmt = ".store/%s/key"
)

// Client talks to one gno.land node.
type Client struct {
	RPC     *rpcclient.RPCClient
	ChainID string
	tx      *gnoclient.Client
	signer  crypto.Address
}

// Dial connects to a node's RPC and reads its chain ID.
func Dial(ctx context.Context, rpcURL string) (*Client, error) {
	rpc, err := rpcclient.NewHTTPClient(rpcURL)
	if err != nil {
		return nil, err
	}
	st, err := rpc.Status(ctx, nil)
	if err != nil {
		return nil, fmt.Errorf("status: %w", err)
	}
	return &Client{RPC: rpc, ChainID: st.NodeInfo.Network}, nil
}

// WithMnemonic sets the key that signs transactions.
func (c *Client) WithMnemonic(mnemonic string) error {
	signer, err := gnoclient.SignerFromBip39(mnemonic, c.ChainID, "", 0, 0)
	if err != nil {
		return err
	}
	info, err := signer.Info()
	if err != nil {
		return err
	}
	c.tx = &gnoclient.Client{Signer: signer, RPCClient: c.RPC}
	c.signer = info.GetAddress()
	return nil
}

// Address is the signer's address.
func (c *Client) Address() crypto.Address { return c.signer }

// LatestHeight is the latest committed block height.
func (c *Client) LatestHeight(ctx context.Context) (int64, error) {
	st, err := c.RPC.Status(ctx, nil)
	if err != nil {
		return 0, err
	}
	return st.SyncInfo.LatestBlockHeight, nil
}

// WaitForHeight blocks until the chain has committed height h.
func (c *Client) WaitForHeight(ctx context.Context, h int64) error {
	for {
		latest, err := c.LatestHeight(ctx)
		if err != nil {
			return err
		}
		if latest >= h {
			return nil
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(300 * time.Millisecond):
		}
	}
}

// SignedHeader returns the header and commit of height h.
func (c *Client) SignedHeader(ctx context.Context, h int64) (*types.SignedHeader, error) {
	res, err := c.RPC.Commit(ctx, &h)
	if err != nil {
		return nil, fmt.Errorf("commit %d: %w", h, err)
	}
	sh := res.SignedHeader
	return &sh, nil
}

// ValidatorSet returns the validator set of height h in the chain's order,
// checked against the hash the header of h commits to.
func (c *Client) ValidatorSet(ctx context.Context, h int64, wantHash []byte) (*types.ValidatorSet, error) {
	res, err := c.RPC.Validators(ctx, &h)
	if err != nil {
		return nil, fmt.Errorf("validators %d: %w", h, err)
	}
	vs := &types.ValidatorSet{Validators: res.Validators}
	if wantHash != nil && !bytes.Equal(vs.Hash(), wantHash) {
		return nil, fmt.Errorf("validator set of height %d does not hash to %X", h, wantHash)
	}
	return vs, nil
}

// ProveKey queries a key of the main store at height h with prove=true. The
// result verifies against the AppHash of the header at h+1. value is nil when
// the key is absent (the ops then prove absence).
func (c *Client) ProveKey(ctx context.Context, key []byte, h int64) (value []byte, ops []merkle.ProofOp, err error) {
	res, err := c.RPC.ABCIQueryWithOptions(ctx, fmt.Sprintf(storeQueryFmt, StoreName), key,
		rpcclient.ABCIQueryOptions{Height: h, Prove: true})
	if err != nil {
		return nil, nil, err
	}
	if res.Response.Error != nil {
		return nil, nil, fmt.Errorf("query: %s (%s)", res.Response.Error, res.Response.Log)
	}
	if res.Response.Height != h {
		return nil, nil, fmt.Errorf("query answered at height %d, want %d", res.Response.Height, h)
	}
	if res.Response.Proof == nil {
		return nil, nil, fmt.Errorf("no proof returned for height %d", h)
	}
	return res.Response.Value, res.Response.Proof.Ops, nil
}

// QEval evaluates a read-only expression in a realm.
func (c *Client) QEval(ctx context.Context, pkgPath, expr string) (string, error) {
	res, err := c.RPC.ABCIQuery(ctx, "vm/qeval", []byte(pkgPath+"."+expr))
	if err != nil {
		return "", err
	}
	if res.Response.Error != nil {
		return "", fmt.Errorf("qeval: %s", res.Response.Log)
	}
	return string(res.Response.Data), nil
}

// TxConfig is gas configuration for submitted transactions.
type TxConfig struct {
	GasFee    string
	GasWanted int64
}

// DefaultTx is generous enough for MsgRun scripts that verify proofs.
var DefaultTx = TxConfig{GasFee: "10000000ugnot", GasWanted: 100_000_000}

// EthClientTx is for scripts carrying Ethereum light-client data: an update
// verifies a 512-key sync committee signature and costs 250M to 400M gas.
var EthClientTx = TxConfig{GasFee: "100000000ugnot", GasWanted: 2_000_000_000}

func (c *Client) base(cfg TxConfig) (gnoclient.BaseTxCfg, error) {
	if c.tx == nil {
		return gnoclient.BaseTxCfg{}, fmt.Errorf("no signer configured")
	}
	acc, _, err := c.tx.QueryAccount(c.signer)
	if err != nil {
		return gnoclient.BaseTxCfg{}, fmt.Errorf("account %s: %w", c.signer, err)
	}
	return gnoclient.BaseTxCfg{
		GasFee: cfg.GasFee, GasWanted: cfg.GasWanted,
		AccountNumber: acc.AccountNumber, SequenceNumber: acc.Sequence,
	}, nil
}

func checkTx(res *ctypes.ResultBroadcastTxCommit, err error) (*ctypes.ResultBroadcastTxCommit, error) {
	if err != nil {
		return nil, err
	}
	if res.CheckTx.IsErr() {
		return res, fmt.Errorf("check tx: %s", res.CheckTx.Log)
	}
	if res.DeliverTx.IsErr() {
		return res, fmt.Errorf("deliver tx: %s", res.DeliverTx.Log)
	}
	return res, nil
}

// Run submits a MsgRun of a single-file main package.
func (c *Client) Run(cfg TxConfig, source string, send std.Coins) (*ctypes.ResultBroadcastTxCommit, error) {
	b, err := c.base(cfg)
	if err != nil {
		return nil, err
	}
	msg := vm.NewMsgRun(c.signer, send, []*std.MemFile{{Name: "main.gno", Body: source}})
	return checkTx(c.tx.Run(b, msg))
}

// Call submits a MsgCall.
func (c *Client) Call(cfg TxConfig, pkgPath, fn string, send std.Coins, args ...string) (*ctypes.ResultBroadcastTxCommit, error) {
	b, err := c.base(cfg)
	if err != nil {
		return nil, err
	}
	return checkTx(c.tx.Call(b, vm.MsgCall{Caller: c.signer, Send: send, PkgPath: pkgPath, Func: fn, Args: args}))
}
