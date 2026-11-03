package main

import (
	"context"
	"encoding/base64"
	"flag"
	"log/slog"
	"os"
	"strings"
	"time"

	"github.com/ethereum/go-ethereum/common"

	"github.com/gnolang/gno-eth-ibc/relayer/arc"
	"github.com/gnolang/gno-eth-ibc/relayer/eth"
	"github.com/gnolang/gno-eth-ibc/relayer/ethgno"
	"github.com/gnolang/gno-eth-ibc/relayer/gno"
	"github.com/gnolang/gno-eth-ibc/relayer/relay"
)

var arcCommands = []command{
	{"gno-create-arc-client", "create gno's Arc light client from the latest Arc block", cmdCreateArcClient},
	{"gno-update-arc-client", "bring gno's Arc light client to the latest Arc block", cmdUpdateArcClient},
	{"relay-arc", "relay Arc -> gno packets sent in an Arc block range", cmdRelayArc},
}

func init() { commands = append(commands, arcCommands...) }

type arcFlags struct {
	gnoRPC, certRPC, proofRPC, depFile, gnoClient *string
}

func newArcFlags(fs *flag.FlagSet) arcFlags {
	return arcFlags{
		gnoRPC:    fs.String("gno-rpc", "http://127.0.0.1:26657", "gno.land RPC"),
		certRPC:   fs.String("arc-cert-rpc", arc.TestnetCertRPC, "Arc RPC serving arc_getCertificate"),
		proofRPC:  fs.String("arc-rpc", arc.TestnetProofRPC, "Arc RPC serving eth_getProof at the latest block (also used for EVM reads)"),
		depFile:   fs.String("deployment", "", "deployment JSON written by DeployGnoIBC.s.sol on Arc"),
		gnoClient: fs.String("gno-client", "", "gno-side Arc client id (default: the deployment's counterpartyClientId)"),
	}
}

func (f arcFlags) dial(ctx context.Context) (*gno.Client, *arc.Client, *eth.Deployment, error) {
	dep, err := eth.LoadDeployment(*f.depFile)
	if err != nil {
		return nil, nil, nil, err
	}
	if *f.gnoClient == "" {
		*f.gnoClient = dep.CounterpartyClientID
	}
	g, err := dialGno(ctx, *f.gnoRPC, true)
	if err != nil {
		return nil, nil, nil, err
	}
	a, err := arc.Dial(ctx, *f.certRPC, *f.proofRPC)
	if err != nil {
		return nil, nil, nil, err
	}
	return g, a, dep, nil
}

func cmdCreateArcClient(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("gno-create-arc-client", flag.ExitOnError)
	f := newArcFlags(fs)
	trusting := fs.Duration("trusting-period", 14*24*time.Hour, "trusting period")
	drift := fs.Duration("max-clock-drift", 90*time.Second, "max clock drift: Arc accepts proposer clocks 30s ahead, and gno.land block time trails real time")
	_ = fs.Parse(args)
	g, a, dep, err := f.dial(ctx)
	if err != nil {
		return err
	}
	s, err := a.LatestSnapshot(ctx, common.Hash{}, common.Address{}, nil)
	if err != nil {
		return err
	}
	msg := arc.EncodeCreation(arc.ClientParams{
		ChainID: dep.ChainID, TrustingPeriod: uint64(trusting.Seconds()), MaxClockDrift: uint64(drift.Seconds()),
		TrustNumerator: 1, TrustDenominator: 3,
		Router: dep.ICS26Router, CommitmentSlot: common.BytesToHash(ethgno.IBCStoreCommitmentSlot),
	}, s)
	res, err := g.Call(gno.EthClientTx, relay.EthRelayRealm, "CreateArcClient", nil, base64.StdEncoding.EncodeToString(msg))
	if err != nil {
		return err
	}
	slog.Info("created Arc client on gno", "clientId", strings.TrimSpace(string(res.DeliverTx.Data)),
		"height", s.Number, "gas", res.DeliverTx.GasUsed)
	return nil
}

func newArcToGno(ctx context.Context, f arcFlags) (*relay.ArcToGno, error) {
	g, a, dep, err := f.dial(ctx)
	if err != nil {
		return nil, err
	}
	e, err := eth.Dial(ctx, *f.proofRPC, "", dep)
	if err != nil {
		return nil, err
	}
	r := &relay.ArcToGno{Gno: g, Arc: a, Eth: e, GnoClientID: *f.gnoClient, Tx: gno.EthClientTx, Log: slog.Default()}
	if key := os.Getenv("ETH_PRIVATE_KEY"); key != "" {
		signer, err := eth.Dial(ctx, *f.proofRPC, key, dep)
		if err != nil {
			return nil, err
		}
		r.AckToArc = &relay.GnoToEth{Gno: g, Eth: signer, GnoClientID: *f.gnoClient}
	}
	return r, nil
}

func cmdUpdateArcClient(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("gno-update-arc-client", flag.ExitOnError)
	f := newArcFlags(fs)
	_ = fs.Parse(args)
	r, err := newArcToGno(ctx, f)
	if err != nil {
		return err
	}
	_, err = r.SnapshotAndUpdate(ctx, nil)
	return err
}

func cmdRelayArc(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("relay-arc", flag.ExitOnError)
	f := newArcFlags(fs)
	from := fs.Uint64("from", 0, "first Arc block to scan (0 = the deployment's deployBlock)")
	to := fs.Uint64("to", 0, "last Arc block to scan (0 = latest)")
	follow := fs.Bool("follow", false, "keep relaying new blocks")
	_ = fs.Parse(args)
	r, err := newArcToGno(ctx, f)
	if err != nil {
		return err
	}
	next := *from
	if next == 0 {
		next = r.Eth.Dep.DeployBlock
	}
	for {
		last := *to
		if last == 0 {
			if last, err = r.Arc.LatestNumber(ctx); err != nil {
				return err
			}
		}
		if next <= last {
			if _, err := r.RelayRange(ctx, next, last); err != nil {
				return err
			}
			next = last + 1
		}
		if !*follow {
			return nil
		}
		select {
		case <-ctx.Done():
			return nil
		case <-time.After(2 * time.Second):
		}
	}
}
