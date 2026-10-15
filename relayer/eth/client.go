// Package eth is the relayer's Ethereum side: ICS26Router, ICS20Transfer and
// GnoLightClient through go-ethereum, using the ABIs Foundry compiled
// (eth/abi, refreshed with `make abis`).
package eth

import (
	"context"
	"crypto/ecdsa"
	"embed"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"os"
	"strings"

	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/accounts/abi/bind"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/ethclient"
)

//go:embed abi/*.json
var abiFS embed.FS

func mustABI(name string) abi.ABI {
	bz, err := abiFS.ReadFile("abi/" + name + ".json")
	if err != nil {
		panic(err)
	}
	a, err := abi.JSON(strings.NewReader(string(bz)))
	if err != nil {
		panic(fmt.Sprintf("%s ABI: %v", name, err))
	}
	return a
}

var (
	RouterABI      = mustABI("ICS26Router")
	TransferABI    = mustABI("ICS20Transfer")
	LightClientABI = mustABI("GnoLightClient")
	ERC20ABI       = mustABI("IBCERC20")
)

// Deployment is the JSON written by contracts/script/DeployGnoIBC.s.sol.
type Deployment struct {
	ChainID              uint64         `json:"chainId"`
	AccessManager        common.Address `json:"accessManager"`
	ICS26Router          common.Address `json:"ics26Router"`
	ICS20Transfer        common.Address `json:"ics20Transfer"`
	GnoLightClient       common.Address `json:"gnoLightClient"`
	GnoChainID           string         `json:"gnoChainId"`
	ClientID             string         `json:"clientId"`
	CounterpartyClientID string         `json:"counterpartyClientId"`
}

// LoadDeployment reads a deployment file.
func LoadDeployment(path string) (*Deployment, error) {
	bz, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var d Deployment
	if err := json.Unmarshal(bz, &d); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	return &d, nil
}

// Client is a connection to an EVM chain plus the IBC contracts on it.
type Client struct {
	EC      *ethclient.Client
	ChainID *big.Int
	Dep     *Deployment
	key     *ecdsa.PrivateKey
	From    common.Address

	Router, Transfer, LightClient *bind.BoundContract
}

// Dial connects to rpcURL. hexKey (0x-optional) signs transactions.
func Dial(ctx context.Context, rpcURL, hexKey string, dep *Deployment) (*Client, error) {
	ec, err := ethclient.DialContext(ctx, rpcURL)
	if err != nil {
		return nil, err
	}
	id, err := ec.ChainID(ctx)
	if err != nil {
		return nil, fmt.Errorf("chain id: %w", err)
	}
	c := &Client{EC: ec, ChainID: id, Dep: dep}
	if hexKey != "" {
		if c.key, err = crypto.HexToECDSA(strings.TrimPrefix(hexKey, "0x")); err != nil {
			return nil, fmt.Errorf("private key: %w", err)
		}
		c.From = crypto.PubkeyToAddress(c.key.PublicKey)
	}
	c.Router = bind.NewBoundContract(dep.ICS26Router, RouterABI, ec, ec, ec)
	c.Transfer = bind.NewBoundContract(dep.ICS20Transfer, TransferABI, ec, ec, ec)
	c.LightClient = bind.NewBoundContract(dep.GnoLightClient, LightClientABI, ec, ec, ec)
	return c, nil
}

func (c *Client) opts(ctx context.Context) (*bind.TransactOpts, error) {
	if c.key == nil {
		return nil, fmt.Errorf("no private key configured")
	}
	o, err := bind.NewKeyedTransactorWithChainID(c.key, c.ChainID)
	if err != nil {
		return nil, err
	}
	o.Context = ctx
	return o, nil
}

// transact sends a transaction and waits for a successful receipt.
func (c *Client) transact(ctx context.Context, bc *bind.BoundContract, method string, args ...any) (*types.Receipt, error) {
	o, err := c.opts(ctx)
	if err != nil {
		return nil, err
	}
	tx, err := bc.Transact(o, method, args...)
	if err != nil {
		// Keep the revert data: it names the contract error.
		var de interface{ ErrorData() interface{} }
		if errors.As(err, &de) && de.ErrorData() != nil {
			return nil, fmt.Errorf("%s: %w (revert data %v)", method, err, de.ErrorData())
		}
		return nil, fmt.Errorf("%s: %w", method, err)
	}
	rcpt, err := bind.WaitMined(ctx, c.EC, tx)
	if err != nil {
		return nil, fmt.Errorf("%s: waiting for %s: %w", method, tx.Hash(), err)
	}
	if rcpt.Status != types.ReceiptStatusSuccessful {
		return rcpt, fmt.Errorf("%s: transaction %s reverted", method, tx.Hash())
	}
	return rcpt, nil
}

func call[T any](ctx context.Context, bc *bind.BoundContract, method string, args ...any) (T, error) {
	return callAt[T](ctx, nil, bc, method, args...)
}

// callAt calls at block (nil = latest). Reads that must see a transaction
// pass its receipt's block: behind a load-balanced RPC, "latest" can be
// served by a node that has not imported it yet.
func callAt[T any](ctx context.Context, block *big.Int, bc *bind.BoundContract, method string, args ...any) (T, error) {
	var zero T
	var out []any
	if err := bc.Call(&bind.CallOpts{Context: ctx, BlockNumber: block}, &out, method, args...); err != nil {
		return zero, fmt.Errorf("%s: %w", method, err)
	}
	if len(out) != 1 {
		return zero, fmt.Errorf("%s: %d return values", method, len(out))
	}
	v, ok := out[0].(T)
	if !ok {
		return zero, fmt.Errorf("%s: unexpected return type %T", method, out[0])
	}
	return v, nil
}
