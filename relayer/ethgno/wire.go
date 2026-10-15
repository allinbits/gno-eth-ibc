package ethgno

import (
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"strings"

	"github.com/gnolang/gno-eth-ibc/relayer/beacon"
)

// Writer encodes the positional wire format of gno.land/p/clockwork/wire:
// Uint is 8 bytes big-endian, Uvarint LEB128, Str and Blob a Uvarint length
// and the bytes, Bool and Byte one byte.
type Writer struct{ buf []byte }

func (w *Writer) Uint(v uint64) *Writer { w.buf = binary.BigEndian.AppendUint64(w.buf, v); return w }

func (w *Writer) Uvarint(v uint64) *Writer { w.buf = binary.AppendUvarint(w.buf, v); return w }

func (w *Writer) Bool(v bool) *Writer {
	if v {
		return w.Byte(1)
	}
	return w.Byte(0)
}

func (w *Writer) Byte(b byte) *Writer { w.buf = append(w.buf, b); return w }

func (w *Writer) Blob(b []byte) *Writer {
	w.Uvarint(uint64(len(b)))
	w.buf = append(w.buf, b...)
	return w
}

func (w *Writer) Str(s string) *Writer { return w.Blob([]byte(s)) }

func (w *Writer) Blobs(bs [][]byte) *Writer {
	w.Uvarint(uint64(len(bs)))
	for _, b := range bs {
		w.Blob(b)
	}
	return w
}

func (w *Writer) Bytes() []byte { return w.buf }

func mustDecodeHex(s string) []byte {
	b, err := hex.DecodeString(strings.TrimPrefix(s, "0x"))
	if err != nil {
		panic(fmt.Sprintf("bad hex %q: %v", s, err))
	}
	return b
}

func hexes(ss []string) [][]byte {
	out := make([][]byte, len(ss))
	for i, s := range ss {
		out[i] = mustDecodeHex(s)
	}
	return out
}

// NonSigner is a sync committee member that did not sign an update, with its
// branch in the committee's pubkeys tree.
type NonSigner struct {
	Pubkey []byte
	Branch [][]byte
}

// NonSigners returns the members of committee whose bit is unset in bits
// (hex), in committee order, with their branches.
func NonSigners(committee beacon.SyncCommittee, bitsHex string) []NonSigner {
	bits := mustDecodeHex(bitsHex)
	keys := hexes(committee.Pubkeys)
	layers := pubkeysTree(keys)
	var out []NonSigner
	for i, pk := range keys {
		if bits[i/8]&(1<<(i%8)) != 0 {
			continue
		}
		var branch [][]byte
		idx := i
		for _, l := range layers[:len(layers)-1] {
			branch = append(branch, l[idx^1])
			idx /= 2
		}
		out = append(out, NonSigner{Pubkey: pk, Branch: branch})
	}
	return out
}

// Summary is a sync committee summary: its pubkeys root and aggregate key.
type Summary struct {
	PubkeysHash     []byte
	AggregatePubkey []byte
}

func Summarize(c beacon.SyncCommittee) Summary {
	layers := pubkeysTree(hexes(c.Pubkeys))
	return Summary{PubkeysHash: layers[len(layers)-1][0], AggregatePubkey: mustDecodeHex(c.AggregatePubkey)}
}

func (w *Writer) lcHeader(h beacon.LightClientHeader) {
	b := h.Beacon
	w.Uint(uint64(b.Slot)).Uint(uint64(b.ProposerIndex)).
		Blob(mustDecodeHex(b.ParentRoot)).Blob(mustDecodeHex(b.StateRoot)).Blob(mustDecodeHex(b.BodyRoot))
	if e := h.Execution; e != nil {
		baseFee, ok := decimalBytes(e.BaseFeePerGas)
		if !ok {
			panic("bad base fee " + e.BaseFeePerGas)
		}
		w.Byte(0).
			Blob(mustDecodeHex(e.ParentHash)).Blob(mustDecodeHex(e.FeeRecipient)).Blob(mustDecodeHex(e.StateRoot)).
			Blob(mustDecodeHex(e.ReceiptsRoot)).Blob(mustDecodeHex(e.LogsBloom)).Blob(mustDecodeHex(e.PrevRandao)).
			Uint(uint64(e.BlockNumber)).Uint(uint64(e.GasLimit)).Uint(uint64(e.GasUsed)).Uint(uint64(e.Timestamp)).
			Blob(mustDecodeHex(e.ExtraData)).Blob(baseFee).Blob(mustDecodeHex(e.BlockHash)).
			Blob(mustDecodeHex(e.TransactionsRoot)).Blob(mustDecodeHex(e.WithdrawalsRoot)).
			Uint(uint64(e.BlobGasUsed)).Uint(uint64(e.ExcessBlobGas))
	} else {
		w.Byte(1).Blob(mustDecodeHex(h.ExecutionBlockHash))
	}
	w.Blobs(hexes(h.ExecutionBranch))
}

func (w *Writer) update(u beacon.LightClientUpdate, active beacon.SyncCommittee, finalizedExecHeader []byte) {
	w.lcHeader(u.AttestedHeader)
	w.Bool(u.NextSyncCommittee != nil)
	if u.NextSyncCommittee != nil {
		s := Summarize(*u.NextSyncCommittee)
		w.Blob(s.PubkeysHash).Blob(s.AggregatePubkey).Blobs(hexes(u.NextSyncCommitteeBranch))
	}
	w.lcHeader(u.FinalizedHeader)
	w.Blobs(hexes(u.FinalityBranch))
	w.Blob(mustDecodeHex(u.SyncAggregate.SyncCommitteeBits)).Blob(mustDecodeHex(u.SyncAggregate.SyncCommitteeSignature))
	w.Uint(uint64(u.SignatureSlot))
	w.Blob(finalizedExecHeader)
	ns := NonSigners(active, u.SyncAggregate.SyncCommitteeBits)
	w.Uvarint(uint64(len(ns)))
	for _, n := range ns {
		w.Blob(n.Pubkey).Blobs(n.Branch)
	}
}

// EncodeHeader encodes an ethereum.Header: u on top of the consensus state at
// trustedSlot, signed by the active committee (the trusted state's current
// one, or its next one if isNext).
func EncodeHeader(u beacon.LightClientUpdate, active beacon.SyncCommittee, isNext bool, trustedSlot uint64, finalizedExecHeader []byte) []byte {
	w := &Writer{}
	w.Uint(trustedSlot).Bool(isNext)
	w.update(u, active, finalizedExecHeader)
	return w.Bytes()
}

// EncodeMembershipProof encodes an ethereum.MembershipProof.
func EncodeMembershipProof(p StorageProof) []byte {
	return (&Writer{}).Blobs(p.AccountProof).Blobs(p.StorageProof).Bytes()
}

// EncodePacketMsg encodes the message of ethrelay.RecvPacket, Acknowledgement
// (when acks is not nil) or Timeout.
func EncodePacketMsg(p Packet, proofSlot uint64, acks [][]byte, proof StorageProof) []byte {
	w := &Writer{}
	w.Uint(p.Sequence).Str(p.SourceClient).Str(p.DestinationClient).Uint(p.TimeoutTimestamp)
	w.Uvarint(uint64(len(p.Payloads)))
	for _, pl := range p.Payloads {
		w.Str(pl.SourcePort).Str(pl.DestinationPort).Str(pl.Version).Str(pl.Encoding).Blob(pl.Value)
	}
	w.Uint(0).Uint(proofSlot)
	if acks != nil {
		w.Blobs(acks)
	}
	w.Blob(EncodeMembershipProof(proof))
	return w.Bytes()
}
