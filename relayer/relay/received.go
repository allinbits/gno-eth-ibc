package relay

import (
	"context"
	"log/slog"

	"github.com/gnolang/gno-eth-ibc/relayer/gno"
	"github.com/gnolang/gno-eth-ibc/relayer/ibc"
)

// ReceiptKey is the main-store key of gno's receipt of a packet received on
// clientID.
func ReceiptKey(clientID string, sequence uint64) []byte {
	return append([]byte(gno.ParamsPrefix), ibc.Path(clientID, ibc.KindPacketReceipt, sequence)...)
}

// gnoReceived reports whether gno already holds a receipt for p, which an
// earlier run delivered. Receiving it again is a no-op on gno that writes no
// acknowledgement, so the relayer skips it rather than wait for one.
func gnoReceived(ctx context.Context, g *gno.Client, p ibc.Packet) (bool, error) {
	h, err := g.LatestHeight(ctx)
	if err != nil {
		return false, err
	}
	v, _, err := g.ProveKey(ctx, ReceiptKey(p.DestinationClient, p.Sequence), h)
	if err != nil {
		return false, err
	}
	return len(v) > 0, nil
}

// skipReceived logs a packet gno already received. When acks is set and the
// sending chain still holds the packet's commitment, gno's acknowledgement
// was not relayed back: it is in a write_acknowledgement event of the earlier
// receive, which relay-gno-acks finds by scanning gno heights.
func skipReceived(ctx context.Context, log *slog.Logger, acks *GnoToEth, p ibc.Packet) error {
	log.Info("packet already received on gno", "client", p.DestinationClient, "sequence", p.Sequence)
	if acks == nil {
		return nil
	}
	c, err := acks.Eth.Commitment(ctx, ibc.Path(p.SourceClient, ibc.KindPacketCommitment, p.Sequence))
	if err != nil {
		return err
	}
	if c != ([32]byte{}) {
		log.Warn("gno's acknowledgement of an earlier receive is not relayed yet; run relay-gno-acks over the gno heights of that receive",
			"client", p.SourceClient, "sequence", p.Sequence)
	}
	return nil
}
