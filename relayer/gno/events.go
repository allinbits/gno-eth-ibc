package gno

import (
	"context"
	"encoding/hex"
	"fmt"

	"github.com/gnolang/gno/gnovm/stdlibs/chain"

	"github.com/gnolang/gno-eth-ibc/relayer/ibc"
)

// Event types and attribute keys emitted by the core realm (core/emit.gno).
const (
	EventSendPacket      = "send_packet"
	EventWriteAck        = "write_acknowledgement"
	EventCreateClient    = "create_client"
	AttrEncodedPacketHex = "encoded_packet_hex"
	AttrEncodedAckHex    = "encoded_acknowledgement_hex"
	AttrClientID         = "client_id"
)

// TxEvent is an event of a successful transaction, with where it happened.
type TxEvent struct {
	Height  int64
	TxIndex int
	Event   chain.Event
}

// Attr returns the value of an attribute, or "".
func (e TxEvent) Attr(key string) string {
	for _, a := range e.Event.Attributes {
		if a.Key == key {
			return a.Value
		}
	}
	return ""
}

// Events returns the events of type typ emitted by pkgPath in heights
// [from, to].
func (c *Client) Events(ctx context.Context, from, to int64, pkgPath, typ string) ([]TxEvent, error) {
	var out []TxEvent
	for h := from; h <= to; h++ {
		res, err := c.RPC.BlockResults(ctx, &h)
		if err != nil {
			return nil, fmt.Errorf("block results %d: %w", h, err)
		}
		if res.Results == nil {
			continue
		}
		for i, dtx := range res.Results.DeliverTxs {
			if dtx.IsErr() {
				continue
			}
			for _, ev := range dtx.Events {
				ge, ok := ev.(chain.Event)
				if !ok || ge.PkgPath != pkgPath || ge.Type != typ {
					continue
				}
				out = append(out, TxEvent{Height: h, TxIndex: i, Event: ge})
			}
		}
	}
	return out, nil
}

// SentPacket is a packet the core realm committed, at the height of its tx.
type SentPacket struct {
	Height int64
	Packet ibc.Packet
}

// SendPackets returns the packets sent in [from, to] by sourceClient ("" for any).
func (c *Client) SendPackets(ctx context.Context, from, to int64, sourceClient string) ([]SentPacket, error) {
	evs, err := c.Events(ctx, from, to, CoreRealm, EventSendPacket)
	if err != nil {
		return nil, err
	}
	var out []SentPacket
	for _, ev := range evs {
		bz, err := hex.DecodeString(ev.Attr(AttrEncodedPacketHex))
		if err != nil {
			return nil, fmt.Errorf("height %d: %s: %w", ev.Height, AttrEncodedPacketHex, err)
		}
		p, err := ibc.DecodePacket(bz)
		if err != nil {
			return nil, fmt.Errorf("height %d: decode packet: %w", ev.Height, err)
		}
		if sourceClient != "" && p.SourceClient != sourceClient {
			continue
		}
		out = append(out, SentPacket{Height: ev.Height, Packet: p})
	}
	return out, nil
}

// PacketCommitmentKey is the main-store key of a packet commitment.
func PacketCommitmentKey(clientID string, sequence uint64) []byte {
	return append([]byte(ParamsPrefix), ibc.Path(clientID, ibc.KindPacketCommitment, sequence)...)
}
