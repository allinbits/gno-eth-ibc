// Package relay moves packets between gno.land and Ethereum. gno_to_eth.go
// is the gno.land -> Ethereum direction; the reverse direction plugs into the
// AckRelayer hook (and later its own file) without touching this one.
package relay

import (
	"bytes"
	"context"
	"fmt"
	"log/slog"
	"math/big"

	"github.com/ethereum/go-ethereum/core/types"

	"github.com/gnolang/gno-eth-ibc/relayer/eth"
	"github.com/gnolang/gno-eth-ibc/relayer/gno"
	"github.com/gnolang/gno-eth-ibc/relayer/gnoibc"
	"github.com/gnolang/gno-eth-ibc/relayer/ibc"
)

// AckRelayer takes acknowledgements written on Ethereum back to gno.land
// (core.Acknowledgement). Proving them on gno needs gno's Ethereum light
// client to have a consensus state covering the EVM block, i.e. a beacon
// chain; see GnoAckSubmitter.
type AckRelayer interface {
	RelayAck(ctx context.Context, w WrittenAck) error
}

// WrittenAck is an acknowledgement ICS26Router committed on Ethereum.
type WrittenAck struct {
	Packet   ibc.Packet
	Acks     [][]byte
	EVMBlock uint64
}

// GnoToEth relays packets sent by the gno core realm on GnoClientID to
// ICS26Router, whose GnoLightClient is registered as EthClientID.
type GnoToEth struct {
	Gno *gno.Client
	Eth *eth.Client
	// GnoClientID is the gno-side (Ethereum) client the packets leave from.
	GnoClientID string
	Ack         AckRelayer
	Log         *slog.Logger
}

// Relayed is the outcome for one packet.
type Relayed struct {
	Packet      ibc.Packet
	ProofHeight ibc.Height
	Update      *types.Receipt // nil if the client was already recent enough
	Recv        *types.Receipt
	Acks        [][]byte
}

// RelayRange relays every packet sent in gno heights [from, to].
func (r *GnoToEth) RelayRange(ctx context.Context, from, to int64) ([]Relayed, error) {
	sent, err := r.Gno.SendPackets(ctx, from, to, r.GnoClientID)
	if err != nil {
		return nil, err
	}
	if len(sent) == 0 {
		return nil, nil
	}
	// One proof height for the whole batch: the state after the latest
	// block whose successor (carrying its AppHash) is committed.
	latest, err := r.Gno.LatestHeight(ctx)
	if err != nil {
		return nil, err
	}
	q := latest - 1
	if q < sent[len(sent)-1].Height {
		if err := r.Gno.WaitForHeight(ctx, sent[len(sent)-1].Height+1); err != nil {
			return nil, err
		}
		q = sent[len(sent)-1].Height
	}
	update, err := r.UpdateClient(ctx, q+1)
	if err != nil {
		return nil, err
	}
	var out []Relayed
	for i, sp := range sent {
		rel, err := r.RelayPacket(ctx, sp.Packet, q)
		if err != nil {
			return out, fmt.Errorf("packet %s/%d: %w", sp.Packet.SourceClient, sp.Packet.Sequence, err)
		}
		if i == 0 {
			rel.Update = update
		}
		out = append(out, rel)
	}
	return out, nil
}

// UpdateClient brings GnoLightClient to gno height target (no-op if it is
// already there or beyond), trusting its latest consensus state.
func (r *GnoToEth) UpdateClient(ctx context.Context, target int64) (*types.Receipt, error) {
	cs, err := r.Eth.LightClientState(ctx)
	if err != nil {
		return nil, err
	}
	trusted := int64(cs.LatestHeight)
	if trusted >= target {
		return nil, nil
	}
	sh, err := r.Gno.SignedHeader(ctx, target)
	if err != nil {
		return nil, err
	}
	vals, err := r.Gno.ValidatorSet(ctx, target, sh.ValidatorsHash)
	if err != nil {
		return nil, err
	}
	trustedCons, err := r.Eth.ConsensusState(ctx, uint64(trusted))
	if err != nil {
		return nil, err
	}
	// Leave out what the client has cached, send the fewest signatures, and
	// when the trusted next set differs (non-adjacent across a set change)
	// fetch it so the chosen signers also meet the trust level over it.
	opts := gnoibc.HeaderOptions{TrustedHeight: trusted}
	var valsHash [32]byte
	copy(valsHash[:], sh.ValidatorsHash)
	if opts.OmitValidators, err = r.Eth.IsValidatorSetCached(ctx, valsHash); err != nil {
		return nil, err
	}
	if !bytes.Equal(vals.Hash(), trustedCons.NextValidatorsHash[:]) {
		if opts.TrustedVals, err = r.Gno.ValidatorSet(ctx, trusted+1, trustedCons.NextValidatorsHash[:]); err != nil {
			return nil, err
		}
		if opts.OmitTrusted, err = r.Eth.IsValidatorSetCached(ctx, trustedCons.NextValidatorsHash); err != nil {
			return nil, err
		}
	}
	hdr, err := gnoibc.EncodeHeader(sh, vals, opts)
	if err != nil {
		return nil, err
	}
	msg, err := gnoibc.PackHeader(hdr)
	if err != nil {
		return nil, err
	}
	rcpt, err := r.Eth.UpdateClient(ctx, msg)
	if err != nil {
		return nil, fmt.Errorf("update %d -> %d: %w", trusted, target, err)
	}
	r.log().Info("updated GnoLightClient", "trusted", trusted, "height", target, "gas", rcpt.GasUsed,
		"signatures", len(hdr.Commit.Signatures)/gnoibc.SigSize, "keysSent", len(hdr.ValidatorSet)+len(hdr.TrustedValidators))
	return rcpt, nil
}

// proofHeight is where Ethereum verifies a proof of gno's state after height
// h: h+1, whose AppHash commits to it, at the revision GnoLightClient's
// client state carries. A client is created at the revision its chain id
// derives (ibc.ParseChainID), but the client's own state is what every proof
// height must match: an existing client keeps the revision it was deployed
// with.
func (r *GnoToEth) proofHeight(ctx context.Context, h int64) (ibc.Height, error) {
	cs, err := r.Eth.LightClientState(ctx)
	if err != nil {
		return ibc.Height{}, err
	}
	return ibc.Height{RevisionNumber: cs.RevisionNumber, RevisionHeight: uint64(h + 1)}, nil
}

// RelayPacket proves p's commitment at gno height q (against the AppHash of
// q+1, which the light client must hold) and submits recvPacket.
func (r *GnoToEth) RelayPacket(ctx context.Context, p ibc.Packet, q int64) (Relayed, error) {
	height, err := r.proofHeight(ctx, q)
	if err != nil {
		return Relayed{Packet: p}, err
	}
	rel := Relayed{Packet: p, ProofHeight: height}
	key := gno.PacketCommitmentKey(p.SourceClient, p.Sequence)
	value, ops, err := r.Gno.ProveKey(ctx, key, q)
	if err != nil {
		return rel, err
	}
	want := p.Commitment()
	if !bytes.Equal(value, want[:]) {
		return rel, fmt.Errorf("stored commitment %X does not match the packet's %X", value, want)
	}
	mp, err := gnoibc.EncodeMembershipProof(ops)
	if err != nil {
		return rel, err
	}
	proof, err := gnoibc.PackMembershipProof(mp)
	if err != nil {
		return rel, err
	}
	// A packet an earlier run delivered is not received again: its
	// acknowledgement is read back from the router's logs and relayed.
	receipt, err := r.Eth.Commitment(ctx, ibc.Path(p.DestinationClient, ibc.KindPacketReceipt, p.Sequence))
	if err != nil {
		return rel, err
	}
	var ackBlock *big.Int
	if receipt != ([32]byte{}) {
		acks, blk, err := r.Eth.WrittenAck(ctx, p.DestinationClient, p.Sequence, 0)
		if err != nil {
			return rel, err
		}
		rel.Acks, ackBlock = acks, new(big.Int).SetUint64(blk)
		r.log().Info("packet already received on Ethereum", "client", p.DestinationClient, "sequence", p.Sequence, "block", blk)
	} else {
		if rel.Recv, err = r.Eth.RecvPacket(ctx, p, proof, rel.ProofHeight); err != nil {
			return rel, err
		}
		acks, err := r.Eth.WrittenAcks(rel.Recv)
		if err != nil {
			return rel, err
		}
		rel.Acks, ackBlock = acks[p.Sequence], rel.Recv.BlockNumber
		if rel.Acks == nil {
			return rel, fmt.Errorf("recvPacket wrote no acknowledgement")
		}
	}
	stored, err := r.Eth.CommitmentAt(ctx, ibc.Path(p.DestinationClient, ibc.KindAcknowledgement, p.Sequence), ackBlock)
	if err != nil {
		return rel, err
	}
	if stored != ibc.AckCommitment(rel.Acks) {
		return rel, fmt.Errorf("ack commitment on Ethereum is %X, want %X", stored, ibc.AckCommitment(rel.Acks))
	}
	if rel.Recv != nil {
		r.log().Info("received packet on Ethereum", "client", p.DestinationClient, "sequence", p.Sequence,
			"gas", rel.Recv.GasUsed, "acks", len(rel.Acks))
	}
	if r.Ack != nil {
		blk := ackBlock.Uint64()
		if err := r.Ack.RelayAck(ctx, WrittenAck{Packet: p, Acks: rel.Acks, EVMBlock: blk}); err != nil {
			return rel, fmt.Errorf("ack back to gno: %w", err)
		}
	}
	return rel, nil
}

func (r *GnoToEth) log() *slog.Logger {
	if r.Log != nil {
		return r.Log
	}
	return slog.Default()
}
