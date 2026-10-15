package relay

import (
	"context"
	"encoding/hex"
	"fmt"
	"log/slog"
	"strings"

	"github.com/gnolang/gno-eth-ibc/relayer/gno"
	"github.com/gnolang/gno-eth-ibc/relayer/ibc"
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

// AckProofSource proves an acknowledgement commitment on Ethereum to gno's
// Ethereum light client. It is implemented with the beacon chain (the
// relayer/beacon and relayer/ethgno packages): updating gno's client to a
// finalized slot covering EVMBlock and rendering an
// ethereum.MembershipProof for ICS26Router's commitment slot.
type AckProofSource interface {
	// AckProof returns a Gno expression of type
	// ethereum.MembershipProof (gno.land/p/aib/ibc/lightclient/ethereum/v0)
	// for the ack commitment of the packet, the proof height it verifies
	// at, and any imports the expression needs besides that package.
	AckProof(ctx context.Context, w WrittenAck) (expr string, proofHeight ibc.Height, imports []string, err error)
}

// GnoAckSubmitter relays acks with core.Acknowledgement in a MsgRun, the
// proof travelling in the message's Ext.
type GnoAckSubmitter struct {
	Gno    *gno.Client
	Proofs AckProofSource
	Tx     gno.TxConfig
}

func (g GnoAckSubmitter) RelayAck(ctx context.Context, w WrittenAck) error {
	expr, h, imports, err := g.Proofs.AckProof(ctx, w)
	if err != nil {
		return err
	}
	src := AcknowledgementScript(w, expr, h, imports)
	if _, err := g.Gno.Run(g.Tx, src, nil); err != nil {
		return fmt.Errorf("core.Acknowledgement: %w", err)
	}
	return nil
}

// AcknowledgementScript renders the MsgRun calling core.Acknowledgement.
func AcknowledgementScript(w WrittenAck, proofExpr string, h ibc.Height, extraImports []string) string {
	var b strings.Builder
	b.WriteString("package main\n\nimport (\n\t\"encoding/hex\"\n\n")
	for _, imp := range append([]string{
		"gno.land/p/aib/ibc/lightclient/ethereum/v0",
		"gno.land/p/aib/ibc/lightclient/extproof/v0",
		"gno.land/p/aib/ibc/types/v0",
		gno.CoreRealm,
	}, extraImports...) {
		fmt.Fprintf(&b, "\t%q\n", imp)
	}
	b.WriteString(")\n\nvar _ ethereum.MembershipProof\n\nfunc h(s string) []byte {\n\tb, err := hex.DecodeString(s)\n\tif err != nil {\n\t\tpanic(err)\n\t}\n\treturn b\n}\n\n")
	b.WriteString("func main(cur realm) {\n\tcore.Acknowledgement(cross(cur), types.MsgAcknowledgement{\n")
	fmt.Fprintf(&b, "\t\tPacket: %s,\n", PacketLiteral(w.Packet))
	b.WriteString("\t\tAcknowledgement: types.Acknowledgement{AppAcknowledgements: [][]byte{")
	for i, a := range w.Acks {
		if i > 0 {
			b.WriteString(", ")
		}
		fmt.Fprintf(&b, "h(%q)", hex.EncodeToString(a))
	}
	b.WriteString("}},\n")
	fmt.Fprintf(&b, "\t\tProofHeight: types.NewHeight(%d, %d),\n", h.RevisionNumber, h.RevisionHeight)
	fmt.Fprintf(&b, "\t\tExt: extproof.Proof{Data: %s},\n\t})\n}\n", proofExpr)
	return b.String()
}

// PacketLiteral renders a types.Packet literal.
func PacketLiteral(p ibc.Packet) string {
	var b strings.Builder
	fmt.Fprintf(&b, "types.Packet{Sequence: %d, SourceClient: %q, DestinationClient: %q, TimeoutTimestamp: %d, Payloads: []types.Payload{",
		p.Sequence, p.SourceClient, p.DestinationClient, p.TimeoutTimestamp)
	for i, pl := range p.Payloads {
		if i > 0 {
			b.WriteString(", ")
		}
		fmt.Fprintf(&b, "{SourcePort: %q, DestinationPort: %q, Version: %q, Encoding: %q, Value: h(%q)}",
			pl.SourcePort, pl.DestinationPort, pl.Version, pl.Encoding, hex.EncodeToString(pl.Value))
	}
	b.WriteString("}}")
	return b.String()
}
