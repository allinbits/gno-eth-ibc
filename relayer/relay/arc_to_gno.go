package relay

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log/slog"
	"strings"

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
}

type arcConsensusState struct {
	Height struct {
		RevisionHeight uint64 `json:"revision_height"`
	} `json:"height"`
	RegistryStorageRoot []byte `json:"registry_storage_root"`
}

// trusted returns gno's client latest height and the registry storage root
// of its block.
func (r *ArcToGno) trusted(ctx context.Context) (uint64, common.Hash, error) {
	g := &EthToGno{Gno: r.Gno}
	js, err := g.render(ctx, "clients/"+r.GnoClientID)
	if err != nil {
		return 0, common.Hash{}, err
	}
	var c struct {
		LastConsensusState *arcConsensusState `json:"last_consensus_state"`
	}
	if err := json.Unmarshal([]byte(js), &c); err != nil || c.LastConsensusState == nil {
		return 0, common.Hash{}, fmt.Errorf("client %s: no latest consensus state in %q", r.GnoClientID, js)
	}
	cs := c.LastConsensusState
	return cs.Height.RevisionHeight, common.BytesToHash(cs.RegistryStorageRoot), nil
}

// SnapshotAndUpdate snapshots the latest Arc block with the router
// commitments at paths, updates gno's client to it and returns the
// snapshot, whose block number is the proof height.
func (r *ArcToGno) SnapshotAndUpdate(ctx context.Context, paths [][]byte) (arc.Snapshot, error) {
	trustedHeight, root, err := r.trusted(ctx)
	if err != nil {
		return arc.Snapshot{}, err
	}
	keys := make([]common.Hash, len(paths))
	for i, p := range paths {
		keys[i] = common.BytesToHash(ethgno.CommitmentSlot(p, ethgno.IBCStoreCommitmentSlot))
	}
	s, err := r.Arc.LatestSnapshot(ctx, root, r.Eth.Dep.ICS26Router, keys)
	if err != nil {
		return arc.Snapshot{}, err
	}
	if s.Number <= trustedHeight {
		return arc.Snapshot{}, fmt.Errorf("snapshot block %d is not after the trusted height %d", s.Number, trustedHeight)
	}
	cert, err := r.Arc.Certificate(ctx, s.Number+1)
	if err != nil {
		return arc.Snapshot{}, err
	}
	_, certified, err := r.Arc.Header(ctx, s.Number+1)
	if err != nil {
		return arc.Snapshot{}, err
	}
	header := arc.EncodeHeader(trustedHeight, cert, certified, s)
	res, err := r.Gno.Call(r.Tx, EthRelayRealm, "UpdateArcClient", nil, r.GnoClientID, base64.StdEncoding.EncodeToString(header))
	if err != nil {
		return arc.Snapshot{}, fmt.Errorf("ethrelay.UpdateArcClient to %d: %w", s.Number, err)
	}
	r.Log.Info("updated gno's Arc client", "client", r.GnoClientID, "height", s.Number,
		"setRead", s.SetIncluded, "gas", res.DeliverTx.GasUsed)
	return s, nil
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
	path := ibc.Path(w.Packet.DestinationClient, ibc.KindAcknowledgement, w.Packet.Sequence)
	snap, err := r.SnapshotAndUpdate(ctx, [][]byte{path})
	if err != nil {
		return err
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
