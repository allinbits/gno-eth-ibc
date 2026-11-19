package relay

import (
	"context"
	"log/slog"
)

// SkipAcks is the AckRelayer for EVM chains without a beacon chain (anvil):
// gno's Ethereum light client cannot be updated there, so acks stay on
// Ethereum. It only logs them.
type SkipAcks struct{ Log *slog.Logger }

func (s SkipAcks) RelayAck(_ context.Context, w WrittenAck) error {
	l := s.Log
	if l == nil {
		l = slog.Default()
	}
	l.Info("ack left on Ethereum: relaying it to gno needs gno's Ethereum client updated past this block",
		"client", w.Packet.SourceClient, "sequence", w.Packet.Sequence, "evmBlock", w.EVMBlock)
	return nil
}
