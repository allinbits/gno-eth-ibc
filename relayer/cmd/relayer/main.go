// Command relayer relays IBC v2 packets between gno.land and an EVM chain.
//
// Secrets come from the environment only: GNO_MNEMONIC signs gno.land
// transactions, ETH_PRIVATE_KEY signs EVM transactions.
//
//	relayer trust                      write GnoLightClient's initial state from a gno header
//	relayer gno-create-eth-client      create a placeholder Ethereum client on gno (local EVM chains)
//	relayer gno-register-counterparty  register the EVM-side client as the gno client's counterparty
//	relayer relay                      relay gno -> EVM packets sent in a height range (once, or -follow)
//	relayer erc20-balance              print an ICS20 voucher balance on the EVM chain
package main

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"strings"
	"time"

	"github.com/ethereum/go-ethereum/common"

	"github.com/gnolang/gno-eth-ibc/relayer/eth"
	"github.com/gnolang/gno-eth-ibc/relayer/gno"
	"github.com/gnolang/gno-eth-ibc/relayer/gnoibc"
	"github.com/gnolang/gno-eth-ibc/relayer/relay"
)

type command struct {
	name, help string
	run        func(ctx context.Context, args []string) error
}

var commands = []command{
	{"trust", "write GnoLightClient's initial client/consensus state (ABI) from a gno header", cmdTrust},
	{"gno-create-eth-client", "create a placeholder Ethereum light client on gno (no beacon chain)", cmdCreateEthClient},
	{"gno-register-counterparty", "register the EVM-side client id as counterparty of a gno client", cmdRegisterCounterparty},
	{"relay", "relay gno -> EVM packets sent in a gno height range", cmdRelay},
	{"erc20-balance", "print the ICS20 voucher balance of an address", cmdBalance},
}

func main() {
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt)
	defer cancel()
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	for _, c := range commands {
		if c.name == os.Args[1] {
			if err := c.run(ctx, os.Args[2:]); err != nil {
				fmt.Fprintln(os.Stderr, "error:", err)
				os.Exit(1)
			}
			return
		}
	}
	usage()
	os.Exit(2)
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: relayer <command> [flags]\n\ncommands:")
	for _, c := range commands {
		fmt.Fprintf(os.Stderr, "  %-26s %s\n", c.name, c.help)
	}
}

func dialGno(ctx context.Context, url string, signer bool) (*gno.Client, error) {
	g, err := gno.Dial(ctx, url)
	if err != nil {
		return nil, err
	}
	if signer {
		m := os.Getenv("GNO_MNEMONIC")
		if m == "" {
			return nil, errors.New("GNO_MNEMONIC is not set")
		}
		if err := g.WithMnemonic(m); err != nil {
			return nil, err
		}
	}
	return g, nil
}

func writeJSON(path string, v any) error {
	bz, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	bz = append(bz, '\n')
	if path == "" || path == "-" {
		_, err = os.Stdout.Write(bz)
		return err
	}
	return os.WriteFile(path, bz, 0o644)
}

func cmdTrust(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("trust", flag.ExitOnError)
	rpc := fs.String("gno-rpc", "http://127.0.0.1:26657", "gno.land RPC")
	height := fs.Int64("height", 0, "trusted height (0 = latest)")
	tp := fs.Duration("trusting-period", 14*24*time.Hour, "trusting period")
	drift := fs.Duration("max-clock-drift", 30*time.Second, "max clock drift")
	out := fs.String("out", "-", "output JSON file")
	_ = fs.Parse(args)
	g, err := dialGno(ctx, *rpc, false)
	if err != nil {
		return err
	}
	cs, cons, err := relay.TrustedState(ctx, g, relay.TrustOptions{Height: *height, TrustingPeriod: *tp, MaxClockDrift: *drift})
	if err != nil {
		return err
	}
	csBz, err := gnoibc.PackClientState(cs)
	if err != nil {
		return err
	}
	consBz, err := gnoibc.PackConsensusState(cons)
	if err != nil {
		return err
	}
	return writeJSON(*out, map[string]any{
		"chainId":        cs.ChainId,
		"height":         cs.LatestHeight,
		"clientState":    "0x" + hex.EncodeToString(csBz),
		"consensusState": "0x" + hex.EncodeToString(consBz),
	})
}

func cmdCreateEthClient(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("gno-create-eth-client", flag.ExitOnError)
	rpc := fs.String("gno-rpc", "http://127.0.0.1:26657", "gno.land RPC")
	chainID := fs.Uint64("evm-chain-id", 31337, "EVM chain id")
	router := fs.String("router", "0x0000000000000000000000000000000000000000", "ICS26Router address (informational for a placeholder)")
	ts := fs.Int64("timestamp", 0, "consensus timestamp, unix seconds (0 = now - 60s); must precede packet timeouts")
	out := fs.String("out", "-", "output JSON file with the client id")
	_ = fs.Parse(args)
	g, err := dialGno(ctx, *rpc, true)
	if err != nil {
		return err
	}
	if *ts == 0 {
		*ts = time.Now().Add(-time.Minute).Unix()
	}
	p := gno.EthPlaceholderClient{EVMChainID: *chainID, Router: common.HexToAddress(*router), Timestamp: uint64(*ts)}
	res, err := g.Run(gno.DefaultTx, gno.CreateEthPlaceholderClientScript(p), nil)
	if err != nil {
		return err
	}
	id := strings.TrimSpace(string(res.DeliverTx.Data))
	slog.Info("created Ethereum client on gno", "clientId", id, "height", res.Height)
	return writeJSON(*out, map[string]any{"clientId": id, "height": res.Height})
}

func cmdRegisterCounterparty(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("gno-register-counterparty", flag.ExitOnError)
	rpc := fs.String("gno-rpc", "http://127.0.0.1:26657", "gno.land RPC")
	client := fs.String("client", "", "gno-side client id")
	counterparty := fs.String("counterparty", "", "EVM-side client id (ICS26Router)")
	prefix := fs.String("prefix", "", "comma-separated hex merkle prefix elements (default: one empty element, as the Ethereum client expects)")
	_ = fs.Parse(args)
	if *client == "" || *counterparty == "" {
		return errors.New("-client and -counterparty are required")
	}
	mp := [][]byte{{}}
	if *prefix != "" {
		mp = nil
		for _, p := range strings.Split(*prefix, ",") {
			bz, err := hex.DecodeString(strings.TrimPrefix(p, "0x"))
			if err != nil {
				return err
			}
			mp = append(mp, bz)
		}
	}
	g, err := dialGno(ctx, *rpc, true)
	if err != nil {
		return err
	}
	if _, err := g.Run(gno.DefaultTx, gno.RegisterCounterpartyScript(*client, mp, *counterparty), nil); err != nil {
		return err
	}
	slog.Info("registered counterparty", "client", *client, "counterparty", *counterparty)
	return nil
}

func cmdRelay(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("relay", flag.ExitOnError)
	gnoRPC := fs.String("gno-rpc", "http://127.0.0.1:26657", "gno.land RPC")
	ethRPC := fs.String("eth-rpc", os.Getenv("ETH_RPC_URL"), "EVM RPC (default $ETH_RPC_URL)")
	depFile := fs.String("deployment", "", "deployment JSON written by DeployGnoIBC.s.sol")
	gnoClient := fs.String("gno-client", "", "gno-side client id the packets are sent on (default: the deployment's counterpartyClientId)")
	from := fs.Int64("from", 1, "first gno height to scan")
	to := fs.Int64("to", 0, "last gno height to scan (0 = latest)")
	follow := fs.Bool("follow", false, "keep relaying new blocks")
	out := fs.String("out", "", "write a JSON summary of the relayed packets")
	_ = fs.Parse(args)

	dep, err := eth.LoadDeployment(*depFile)
	if err != nil {
		return err
	}
	if *gnoClient == "" {
		*gnoClient = dep.CounterpartyClientID
	}
	g, err := dialGno(ctx, *gnoRPC, false)
	if err != nil {
		return err
	}
	e, err := eth.Dial(ctx, *ethRPC, os.Getenv("ETH_PRIVATE_KEY"), dep)
	if err != nil {
		return err
	}
	r := &relay.GnoToEth{Gno: g, Eth: e, GnoClientID: *gnoClient, Ack: relay.SkipAcks{}}

	var summary []map[string]any
	next := *from
	for {
		last := *to
		if last == 0 {
			if last, err = g.LatestHeight(ctx); err != nil {
				return err
			}
		}
		if next <= last {
			rels, err := r.RelayRange(ctx, next, last)
			if err != nil {
				return err
			}
			for _, rel := range rels {
				s := map[string]any{
					"sourceClient": rel.Packet.SourceClient, "destClient": rel.Packet.DestinationClient,
					"sequence": rel.Packet.Sequence, "proofHeight": rel.ProofHeight.RevisionHeight,
					"recvTx": rel.Recv.TxHash.Hex(), "recvGas": rel.Recv.GasUsed,
					"acks": hexAll(rel.Acks),
				}
				if rel.Update != nil {
					s["updateTx"], s["updateGas"] = rel.Update.TxHash.Hex(), rel.Update.GasUsed
				}
				summary = append(summary, s)
			}
			next = last + 1
		}
		if !*follow {
			break
		}
		select {
		case <-ctx.Done():
			return nil
		case <-time.After(2 * time.Second):
		}
	}
	slog.Info("relay done", "packets", len(summary))
	if *out != "" {
		return writeJSON(*out, summary)
	}
	return nil
}

func hexAll(bzs [][]byte) []string {
	out := make([]string, len(bzs))
	for i, b := range bzs {
		out[i] = "0x" + hex.EncodeToString(b)
	}
	return out
}

func cmdBalance(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("erc20-balance", flag.ExitOnError)
	ethRPC := fs.String("eth-rpc", os.Getenv("ETH_RPC_URL"), "EVM RPC (default $ETH_RPC_URL)")
	depFile := fs.String("deployment", "", "deployment JSON")
	denom := fs.String("denom", "", "full ICS20 denom path, e.g. transfer/client-0/ugnot")
	owner := fs.String("owner", "", "address")
	_ = fs.Parse(args)
	dep, err := eth.LoadDeployment(*depFile)
	if err != nil {
		return err
	}
	e, err := eth.Dial(ctx, *ethRPC, "", dep)
	if err != nil {
		return err
	}
	token, err := e.IBCERC20(ctx, *denom)
	if err != nil {
		return err
	}
	if token == (common.Address{}) {
		return fmt.Errorf("no IBCERC20 for denom %q", *denom)
	}
	bal, err := e.BalanceOf(ctx, token, common.HexToAddress(*owner))
	if err != nil {
		return err
	}
	return writeJSON("-", map[string]any{"denom": *denom, "token": token.Hex(), "owner": *owner, "balance": bal.String()})
}
