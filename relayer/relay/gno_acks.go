package relay

import (
	"bytes"
	"context"
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
	rcpt, err := r.Eth.AckPacket(ctx, p, ack, proof, ibc.Height{RevisionHeight: uint64(h + 1)})
	if err != nil {
		return err
	}
	r.log().Info("acknowledged packet on Ethereum", "client", p.SourceClient, "sequence", p.Sequence,
		"proofHeight", h+1, "gas", rcpt.GasUsed)
	return nil
}
