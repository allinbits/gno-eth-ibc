package relay

import (
	"bytes"
	"context"
	"encoding/hex"
	"fmt"

	"github.com/gnolang/gno-eth-ibc/relayer/gno"
	"github.com/gnolang/gno-eth-ibc/relayer/gnoibc"
	"github.com/gnolang/gno-eth-ibc/relayer/ibc"
)

// RelayGnoAck delivers to the EVM chain the acknowledgement gno wrote at
// height h for packet p (sent from the EVM chain): it updates GnoLightClient
// to h+1, whose AppHash commits to the state after h, proves the ack
// commitment there and calls ackPacket.
func (r *GnoToEth) RelayGnoAck(ctx context.Context, p ibc.Packet, ack []byte, h int64) error {
	if err := r.Gno.WaitForHeight(ctx, h+1); err != nil {
		return err
	}
	if _, err := r.UpdateClient(ctx, h+1); err != nil {
		return err
	}
	key := append([]byte(gno.ParamsPrefix), ibc.Path(p.DestinationClient, ibc.KindAcknowledgement, p.Sequence)...)
	value, ops, err := r.Gno.ProveKey(ctx, key, h)
	if err != nil {
		return err
	}
	want := ibc.AckCommitment([][]byte{ack})
	if !bytes.Equal(value, want[:]) {
		return fmt.Errorf("stored ack commitment %X does not match the ack's %X", value, want)
	}
	mp, err := gnoibc.EncodeMembershipProof(ops)
	if err != nil {
		return err
	}
	proof, err := gnoibc.PackMembershipProof(mp)
	if err != nil {
		return err
	}
	height, err := r.proofHeight(ctx, h)
	if err != nil {
		return err
	}
	rcpt, err := r.Eth.AckPacket(ctx, p, ack, proof, height)
	if err != nil {
		return err
	}
	r.log().Info("acknowledged packet on Ethereum", "client", p.SourceClient, "sequence", p.Sequence,
		"proofHeight", h+1, "gas", rcpt.GasUsed)
	return nil
}

// RelayGnoAcks relays to the EVM chain the acknowledgements gno wrote in
// heights [from, to] for packets received on GnoClientID (sent from the EVM
// chain) that the EVM chain has not acknowledged yet. It resumes after a
// restart and covers asynchronous acknowledgements.
func (r *GnoToEth) RelayGnoAcks(ctx context.Context, from, to int64) (int, error) {
	evs, err := r.Gno.Events(ctx, from, to, gno.CoreRealm, gno.EventWriteAck)
	if err != nil {
		return 0, err
	}
	n := 0
	for _, ev := range evs {
		pbz, err := hex.DecodeString(ev.Attr("encoded_packet_hex"))
		if err != nil {
			return n, err
		}
		p, err := ibc.DecodePacket(pbz)
		if err != nil {
			return n, err
		}
		if p.DestinationClient != r.GnoClientID {
			continue
		}
		abz, err := hex.DecodeString(ev.Attr("encoded_acknowledgement_hex"))
		if err != nil {
			return n, err
		}
		acks, err := ibc.DecodeAcknowledgement(abz)
		if err != nil {
			return n, err
		}
		if len(acks) != 1 {
			return n, fmt.Errorf("packet %d: %d app acknowledgements, want 1", p.Sequence, len(acks))
		}
		// The EVM chain deletes its commitment when it processes the ack.
		c, err := r.Eth.Commitment(ctx, ibc.Path(p.SourceClient, ibc.KindPacketCommitment, p.Sequence))
		if err != nil {
			return n, err
		}
		if c == ([32]byte{}) {
			continue
		}
		if err := r.RelayGnoAck(ctx, p, acks[0], ev.Height); err != nil {
			return n, fmt.Errorf("packet %d: %w", p.Sequence, err)
		}
		n++
	}
	return n, nil
}
