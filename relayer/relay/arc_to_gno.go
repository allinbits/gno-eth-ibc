package relay

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log/slog"
	"strings"
	"time"

	"github.com/ethereum/go-ethereum/common"

	"github.com/gnolang/gno-eth-ibc/relayer/arc"
	"github.com/gnolang/gno-eth-ibc/relayer/eth"
	"github.com/gnolang/gno-eth-ibc/relayer/ethgno"
	"github.com/gnolang/gno-eth-ibc/relayer/gno"
	"github.com/gnolang/gno-eth-ibc/relayer/ibc"
)

// ArcToGno relays Arc to gno.land through EthRelayRealm: it updates gno's
// Arc light client (GnoClientID) and delivers the packets and
// acknowledgements Arc's ICS26 router wrote.
//
// Arc's public RPC nodes prove only the latest state, so every delivery
// reads one snapshot of the latest block B (the registry's proof and the
// router commitments it needs), updates the client to B with the commit
// certificate of B+1, and proves against B.
type ArcToGno struct {
	Gno *gno.Client
	Arc *arc.Client
	// Eth reads the router's events on Arc (eth.Client works on any EVM
	// chain with a deployment record).
	Eth         *eth.Client
	GnoClientID string
	Tx          gno.TxConfig
	Log         *slog.Logger
	// AckToArc, when set, delivers to Arc the acknowledgements gno writes for
	// the packets this relayer delivers.
	AckToArc *GnoToEth
	// BlockWait is the pause between polls of a lagging proof RPC (default
	// one second).
	BlockWait time.Duration
}

func (r *ArcToGno) blockWait() time.Duration {
	if r.BlockWait > 0 {
		return r.BlockWait
	}
	return arcBlockWait
}

type arcClientState struct {
	RegistryAddress         []byte `json:"registry_address"`
	RegistryStorageLocation []byte `json:"registry_storage_location"`
}

type arcConsensusState struct {
	Height struct {
		RevisionHeight uint64 `json:"revision_height"`
	} `json:"height"`
	RegistryStorageRoot []byte `json:"registry_storage_root"`
}

// trusted returns gno's client latest height, the registry storage root of
// its block, and the registry the client reads: a recovery may have moved its
// storage location, so it comes from the client state.
func (r *ArcToGno) trusted(ctx context.Context) (uint64, common.Hash, arc.Registry, error) {
	g := &EthToGno{Gno: r.Gno}
	js, err := g.render(ctx, "clients/"+r.GnoClientID)
	if err != nil {
		return 0, common.Hash{}, arc.Registry{}, err
	}
	return parseArcClient(r.GnoClientID, js)
}

func parseArcClient(clientID, js string) (uint64, common.Hash, arc.Registry, error) {
	var c struct {
		ClientState        *arcClientState    `json:"client_state"`
		LastConsensusState *arcConsensusState `json:"last_consensus_state"`
	}
	if err := json.Unmarshal([]byte(js), &c); err != nil || c.LastConsensusState == nil || c.ClientState == nil {
		return 0, common.Hash{}, arc.Registry{}, fmt.Errorf("client %s: no client state or latest consensus state in %q", clientID, js)
	}
	if len(c.ClientState.RegistryAddress) != common.AddressLength || len(c.ClientState.RegistryStorageLocation) != common.HashLength {
		return 0, common.Hash{}, arc.Registry{}, fmt.Errorf("client %s: malformed registry in %q", clientID, js)
	}
	reg := arc.Registry{
		Address:         common.BytesToAddress(c.ClientState.RegistryAddress),
		StorageLocation: common.BytesToHash(c.ClientState.RegistryStorageLocation),
	}
	cs := c.LastConsensusState
	return cs.Height.RevisionHeight, common.BytesToHash(cs.RegistryStorageRoot), reg, nil
}

// SnapshotAndUpdate snapshots the latest Arc block with the router
// commitments at paths, updates gno's client to it and returns the
// snapshot, whose block number is the proof height.
//
// relay-arc and relay -arc both update the client, and an update must build
// on its latest trusted height and go past it. So an attempt waits for the
// proof RPC to serve a block past the trusted height (the other relayer may
// have moved the client beyond it), and one the other relayer overtook is
// retried from the new trusted state.
func (r *ArcToGno) SnapshotAndUpdate(ctx context.Context, paths [][]byte) (arc.Snapshot, error) {
	var err error
	for attempt := 1; attempt <= updateAttempts; attempt++ {
		var s arc.Snapshot
		var retry bool
		if s, retry, err = r.snapshotAndUpdate(ctx, paths); err == nil || !retry {
			return s, err
		}
		r.Log.Warn("another relayer moved gno's Arc client; retrying", "client", r.GnoClientID, "attempt", attempt, "err", err)
	}
	return arc.Snapshot{}, err
}

const updateAttempts = 5

// snapshotAndUpdate makes one attempt. retry reports a failure another
// relayer's update explains: the snapshot is not past the trusted height
// (a load-balanced proof RPC served an older block), or the update failed
// and the trusted height moved meanwhile.
func (r *ArcToGno) snapshotAndUpdate(ctx context.Context, paths [][]byte) (arc.Snapshot, bool, error) {
	trustedHeight, root, reg, err := r.trusted(ctx)
	if err != nil {
		return arc.Snapshot{}, false, err
	}
	if err := waitBlock(ctx, r.Arc.LatestNumber, trustedHeight+1, arcBlockAttempts, r.blockWait()); err != nil {
		return arc.Snapshot{}, false, err
	}
	keys := make([]common.Hash, len(paths))
	for i, p := range paths {
		keys[i] = common.BytesToHash(ethgno.CommitmentSlot(p, ethgno.IBCStoreCommitmentSlot))
	}
	s, err := r.Arc.LatestSnapshot(ctx, reg, root, r.Eth.Dep.ICS26Router, keys)
	if err != nil {
		return arc.Snapshot{}, false, err
	}
	if s.Number <= trustedHeight {
		return arc.Snapshot{}, true, fmt.Errorf("snapshot block %d is not after the trusted height %d", s.Number, trustedHeight)
	}
	cert, err := r.Arc.Certificate(ctx, s.Number+1)
	if err != nil {
		return arc.Snapshot{}, false, err
	}
	_, certified, err := r.Arc.Header(ctx, s.Number+1)
	if err != nil {
		return arc.Snapshot{}, false, err
	}
	header := arc.EncodeHeader(trustedHeight, cert, certified, s)
	res, err := r.Gno.Call(r.Tx, EthRelayRealm, "UpdateArcClient", nil, r.GnoClientID, base64.StdEncoding.EncodeToString(header))
	if err != nil {
		now, _, _, terr := r.trusted(ctx)
		return arc.Snapshot{}, terr == nil && now != trustedHeight, fmt.Errorf("ethrelay.UpdateArcClient to %d: %w", s.Number, err)
	}
	r.Log.Info("updated gno's Arc client", "client", r.GnoClientID, "height", s.Number,
		"setRead", s.SetIncluded, "gas", res.DeliverTx.GasUsed)
	return s, false, nil
}

// proofOf is the membership proof of the router commitment at path in s.
func proofOf(s arc.Snapshot, path []byte) ethgno.StorageProof {
	key := common.BytesToHash(ethgno.CommitmentSlot(path, ethgno.IBCStoreCommitmentSlot))
	v := s.Router.Values[key]
	return ethgno.StorageProof{AccountProof: s.Router.AccountProof, StorageProof: s.Router.Nodes, Value: v[:]}
}

// RelayRange delivers to gno the packets the router sent to GnoClientID in
// Arc blocks [from, to], all proven against one snapshot.
func (r *ArcToGno) RelayRange(ctx context.Context, from, to uint64) ([]EthRelayed, error) {
	sent, err := r.Eth.SendPackets(ctx, from, to)
	if err != nil {
		return nil, err
	}
	var todo []ibc.Packet
	var paths [][]byte
	for _, s := range sent {
		if s.Packet.DestinationClient == r.GnoClientID {
			received, err := gnoReceived(ctx, r.Gno, s.Packet)
			if err != nil {
				return nil, err
			}
			if received {
				if err := skipReceived(ctx, r.Log, r.AckToArc, s.Packet); err != nil {
					return nil, err
				}
				continue
			}
			todo = append(todo, s.Packet)
			paths = append(paths, ibc.Path(s.Packet.SourceClient, ibc.KindPacketCommitment, s.Packet.Sequence))
		}
	}
	if len(todo) == 0 {
		return nil, nil
	}
	snap, err := r.SnapshotAndUpdate(ctx, paths)
	if err != nil {
		return nil, err
	}
	var out []EthRelayed
	for i, p := range todo {
		msg := ethgno.EncodePacketMsg(toEthgnoPacket(p), snap.Number, nil, proofOf(snap, paths[i]))
		res, err := r.Gno.Call(r.Tx, EthRelayRealm, "RecvPacket", nil, base64.StdEncoding.EncodeToString(msg))
		if err != nil {
			return out, fmt.Errorf("core.RecvPacket %d: %w", p.Sequence, err)
		}
		rel := EthRelayed{Packet: p, ProofSlot: snap.Number, RecvGas: res.DeliverTx.GasUsed,
			Result: strings.TrimSpace(string(res.DeliverTx.Data))}
		r.Log.Info("received Arc packet on gno", "client", r.GnoClientID, "sequence", p.Sequence,
			"proofHeight", snap.Number, "gas", rel.RecvGas, "result", rel.Result)
		out = append(out, rel)
		if r.AckToArc == nil {
			continue
		}
		ack, err := writtenGnoAck(res, p)
		if err != nil {
			return out, err
		}
		if err := r.AckToArc.RelayGnoAck(ctx, p, ack, res.Height); err != nil {
			return out, fmt.Errorf("ack %d to Arc: %w", p.Sequence, err)
		}
	}
	return out, nil
}

// RelayAck implements AckRelayer: it proves the acknowledgement Arc's router
// wrote and delivers it with ethrelay.Acknowledgement.
func (r *ArcToGno) RelayAck(ctx context.Context, w WrittenAck) error {
	// An ack an earlier run delivered deleted gno's commitment: skip it
	// rather than pay for a client update.
	h, err := r.Gno.LatestHeight(ctx)
	if err != nil {
		return err
	}
	c, _, err := r.Gno.ProveKey(ctx, gno.PacketCommitmentKey(w.Packet.SourceClient, w.Packet.Sequence), h)
	if err != nil {
		return err
	}
	if len(c) == 0 {
		r.Log.Info("packet already acknowledged on gno", "client", w.Packet.SourceClient, "sequence", w.Packet.Sequence)
		return nil
	}
	// The ack was seen at w.EVMBlock, maybe through another RPC than the
	// one serving proofs, which may lag: snapshot only once it has the
	// block.
	if err := waitBlock(ctx, r.Arc.LatestNumber, w.EVMBlock, arcBlockAttempts, r.blockWait()); err != nil {
		return fmt.Errorf("ack %d: %w", w.Packet.Sequence, err)
	}
	path := ibc.Path(w.Packet.DestinationClient, ibc.KindAcknowledgement, w.Packet.Sequence)
	snap, err := r.SnapshotAndUpdate(ctx, [][]byte{path})
	if err != nil {
		return err
	}
	if snap.Number < w.EVMBlock {
		return fmt.Errorf("ack %d: snapshot block %d is before the ack's block %d", w.Packet.Sequence, snap.Number, w.EVMBlock)
	}
	msg := ethgno.EncodePacketMsg(toEthgnoPacket(w.Packet), snap.Number, w.Acks, proofOf(snap, path))
	res, err := r.Gno.Call(r.Tx, EthRelayRealm, "Acknowledgement", nil, base64.StdEncoding.EncodeToString(msg))
	if err != nil {
		return fmt.Errorf("ethrelay.Acknowledgement %d: %w", w.Packet.Sequence, err)
	}
	r.Log.Info("acknowledged packet on gno", "client", w.Packet.SourceClient, "sequence", w.Packet.Sequence,
		"proofHeight", snap.Number, "gas", res.DeliverTx.GasUsed)
	return nil
}

const (
	arcBlockAttempts = 60
	arcBlockWait     = time.Second
)

// waitBlock polls latest until it reports block n or later, at most attempts
// times, wait apart.
func waitBlock(ctx context.Context, latest func(context.Context) (uint64, error), n uint64, attempts int, wait time.Duration) error {
	var last uint64
	for i := 0; i < attempts; i++ {
		got, err := latest(ctx)
		if err != nil {
			return err
		}
		if got >= n {
			return nil
		}
		last = got
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(wait):
		}
	}
	return fmt.Errorf("the proof RPC is at block %d, still before block %d", last, n)
}
