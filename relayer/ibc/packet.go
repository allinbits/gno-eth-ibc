// Package ibc holds the chain-agnostic IBC v2 types the relayer moves between
// gno.land and Ethereum, with the encodings both sides agree on.
package ibc

import (
	"crypto/sha256"
	"encoding/binary"
	"fmt"

	"google.golang.org/protobuf/encoding/protowire"
)

// Payload is an IBC v2 payload (ibc.core.channel.v2.Payload).
type Payload struct {
	SourcePort      string
	DestinationPort string
	Version         string
	Encoding        string
	Value           []byte
}

// Packet is an IBC v2 packet (ibc.core.channel.v2.Packet).
type Packet struct {
	Sequence          uint64
	SourceClient      string
	DestinationClient string
	TimeoutTimestamp  uint64 // unix seconds
	Payloads          []Payload
}

// Height is an IBC height.
type Height struct {
	RevisionNumber uint64
	RevisionHeight uint64
}

// Commitment path kinds, as in ICS24 / gno.land/p/aib/ibc/host.
const (
	KindPacketCommitment byte = 0x01
	KindPacketReceipt    byte = 0x02
	KindAcknowledgement  byte = 0x03
)

// Path is clientID || kind || uint64_be(sequence): the ICS24 v2 path that
// both the gno core realm (params key suffix) and ICS26Router use.
func Path(clientID string, kind byte, sequence uint64) []byte {
	var be [8]byte
	binary.BigEndian.PutUint64(be[:], sequence)
	out := append([]byte(clientID), kind)
	return append(out, be[:]...)
}

// Commitment is the IBC v2 packet commitment
// sha256(0x02 || sha256(dest) || sha256(timeout_be) || sha256(sha256-of-payloads)).
func (p Packet) Commitment() [32]byte {
	var app []byte
	for _, pl := range p.Payloads {
		h := sha256.New()
		for _, b := range [][]byte{[]byte(pl.SourcePort), []byte(pl.DestinationPort), []byte(pl.Version), []byte(pl.Encoding), pl.Value} {
			s := sha256.Sum256(b)
			h.Write(s[:])
		}
		app = h.Sum(app)
	}
	var be [8]byte
	binary.BigEndian.PutUint64(be[:], p.TimeoutTimestamp)
	dst := sha256.Sum256([]byte(p.DestinationClient))
	tmo := sha256.Sum256(be[:])
	apps := sha256.Sum256(app)
	buf := append([]byte{2}, dst[:]...)
	buf = append(buf, tmo[:]...)
	buf = append(buf, apps[:]...)
	return sha256.Sum256(buf)
}

// AckCommitment is sha256(0x02 || sha256(ack_1) || ...).
func AckCommitment(acks [][]byte) [32]byte {
	buf := []byte{2}
	for _, a := range acks {
		s := sha256.Sum256(a)
		buf = append(buf, s[:]...)
	}
	return sha256.Sum256(buf)
}

// DecodePacket parses the protobuf encoding that gno's core realm emits as
// encoded_packet_hex (gno.land/p/aib/ibc/types Packet.ProtoMarshal).
func DecodePacket(bz []byte) (Packet, error) {
	var p Packet
	err := walk(bz, func(num protowire.Number, v uint64, b []byte) error {
		switch num {
		case 1:
			p.Sequence = v
		case 2:
			p.SourceClient = string(b)
		case 3:
			p.DestinationClient = string(b)
		case 4:
			p.TimeoutTimestamp = v
		case 5:
			pl, err := decodePayload(b)
			if err != nil {
				return err
			}
			p.Payloads = append(p.Payloads, pl)
		}
		return nil
	})
	return p, err
}

func decodePayload(bz []byte) (Payload, error) {
	var pl Payload
	err := walk(bz, func(num protowire.Number, _ uint64, b []byte) error {
		switch num {
		case 1:
			pl.SourcePort = string(b)
		case 2:
			pl.DestinationPort = string(b)
		case 3:
			pl.Version = string(b)
		case 4:
			pl.Encoding = string(b)
		case 5:
			pl.Value = append([]byte{}, b...)
		}
		return nil
	})
	return pl, err
}

// DecodeAcknowledgement decodes the protobuf Acknowledgement gno emits
// (repeated bytes app_acknowledgements = 1) into its app acknowledgements.
func DecodeAcknowledgement(bz []byte) ([][]byte, error) {
	var acks [][]byte
	err := walk(bz, func(num protowire.Number, _ uint64, b []byte) error {
		if num == 1 {
			acks = append(acks, append([]byte{}, b...))
		}
		return nil
	})
	return acks, err
}

func walk(bz []byte, f func(num protowire.Number, v uint64, b []byte) error) error {
	for len(bz) > 0 {
		num, typ, n := protowire.ConsumeTag(bz)
		if n < 0 {
			return protowire.ParseError(n)
		}
		bz = bz[n:]
		switch typ {
		case protowire.VarintType:
			v, m := protowire.ConsumeVarint(bz)
			if m < 0 {
				return protowire.ParseError(m)
			}
			bz = bz[m:]
			if err := f(num, v, nil); err != nil {
				return err
			}
		case protowire.BytesType:
			b, m := protowire.ConsumeBytes(bz)
			if m < 0 {
				return protowire.ParseError(m)
			}
			bz = bz[m:]
			if err := f(num, 0, b); err != nil {
				return err
			}
		default:
			return fmt.Errorf("unexpected wire type %d for field %d", typ, num)
		}
	}
	return nil
}
