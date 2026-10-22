package eth

import (
	"context"
	"errors"
	"math/big"
	"slices"
	"testing"

	"github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
)

// fakeLogs serves logs by block as a public RPC does: a range wider than
// maxRange is refused. It records every range it was asked.
type fakeLogs struct {
	head     uint64
	maxRange uint64
	logs     []types.Log // ascending by block
	ranges   [][2]uint64
}

func (f *fakeLogs) BlockNumber(context.Context) (uint64, error) { return f.head, nil }

func (f *fakeLogs) FilterLogs(_ context.Context, q ethereum.FilterQuery) ([]types.Log, error) {
	from, to := q.FromBlock.Uint64(), q.ToBlock.Uint64()
	f.ranges = append(f.ranges, [2]uint64{from, to})
	if to-from+1 > f.maxRange {
		return nil, errors.New("getLogs request exceeded max allowed range")
	}
	var out []types.Log
	for _, l := range f.logs {
		if l.BlockNumber >= from && l.BlockNumber <= to && matches(q, l) {
			out = append(out, l)
		}
	}
	return out, nil
}

func matches(q ethereum.FilterQuery, l types.Log) bool {
	if len(q.Addresses) > 0 && !slices.Contains(q.Addresses, l.Address) {
		return false
	}
	for i, want := range q.Topics {
		if len(want) > 0 && (i >= len(l.Topics) || !slices.Contains(want, l.Topics[i])) {
			return false
		}
	}
	return true
}

// accepted returns the ranges the source served, in order.
func (f *fakeLogs) accepted() [][2]uint64 {
	var out [][2]uint64
	for _, r := range f.ranges {
		if r[1]-r[0]+1 <= f.maxRange {
			out = append(out, r)
		}
	}
	return out
}

func blocks(logs []types.Log) []uint64 {
	out := make([]uint64, len(logs))
	for i, l := range logs {
		out[i] = l.BlockNumber
	}
	return out
}

func TestScanLogsChunksAndHalvesOnRefusal(t *testing.T) {
	src := &fakeLogs{maxRange: 3_000, logs: []types.Log{{BlockNumber: 150}, {BlockNumber: 9_999}, {BlockNumber: 25_000}}}
	c := &Client{Logs: src}
	got, err := c.allLogs(context.Background(), ethereum.FilterQuery{}, 100, 25_000)
	if err != nil {
		t.Fatal(err)
	}
	if want := []uint64{150, 9_999, 25_000}; !slices.Equal(blocks(got), want) {
		t.Errorf("logs at %v, want %v", blocks(got), want)
	}
	// 10,000 and 5,000 blocks refused, then 2,500-block chunks covering the range once, in order
	if refused := len(src.ranges) - len(src.accepted()); refused != 2 {
		t.Errorf("%d refused requests, want 2: %v", refused, src.ranges)
	}
	next := uint64(100)
	for _, r := range src.accepted() {
		if r[0] != next || r[1] < r[0] {
			t.Fatalf("range %v breaks the sequence at %d: %v", r, next, src.ranges)
		}
		next = r[1] + 1
	}
	if next != 25_001 {
		t.Errorf("scan ended at %d, want 25000", next-1)
	}
	if c.logChunk != 2_500 {
		t.Errorf("chunk settled at %d, want 2500", c.logChunk)
	}
}

func TestLastLogScansNewestFirstAndStops(t *testing.T) {
	src := &fakeLogs{maxRange: 3_000, logs: []types.Log{{BlockNumber: 150}, {BlockNumber: 20_000}}}
	c := &Client{Logs: src}
	l, ok, err := c.lastLog(context.Background(), ethereum.FilterQuery{}, 100, 25_000)
	if err != nil || !ok || l.BlockNumber != 20_000 {
		t.Fatalf("got %v %v %v, want the log of block 20000", l.BlockNumber, ok, err)
	}
	acc := src.accepted()
	if acc[0][1] != 25_000 {
		t.Errorf("the scan started at %v, not at the head", acc[0])
	}
	for i := 1; i < len(acc); i++ {
		if acc[i][1] != acc[i-1][0]-1 {
			t.Errorf("ranges %v and %v are not consecutive newest first", acc[i-1], acc[i])
		}
	}
	if last := acc[len(acc)-1]; last[0] > 20_000 || last[0] <= 150 {
		t.Errorf("the scan stopped at %v: it must cover block 20000 and never reach block 150", last)
	}
}

func TestLastLogNone(t *testing.T) {
	src := &fakeLogs{maxRange: 3_000}
	c := &Client{Logs: src}
	if _, ok, err := c.lastLog(context.Background(), ethereum.FilterQuery{}, 0, 5_000); ok || err != nil {
		t.Fatalf("got %v %v, want no log", ok, err)
	}
	if acc := src.accepted(); acc[len(acc)-1][0] != 0 {
		t.Errorf("the scan did not reach block 0: %v", src.ranges)
	}
}

func TestScanLogsReturnsAPersistentError(t *testing.T) {
	src := &fakeLogs{} // refuses everything
	c := &Client{Logs: src}
	_, err := c.allLogs(context.Background(), ethereum.FilterQuery{}, 1, 100)
	if err == nil {
		t.Fatal("no error")
	}
	if last := src.ranges[len(src.ranges)-1]; last[0] != last[1] {
		t.Errorf("gave up on a %d-block request, not on a single block", last[1]-last[0]+1)
	}
	if len(src.ranges) > 10 {
		t.Errorf("%d requests before giving up", len(src.ranges))
	}
}

var router = common.HexToAddress("0x24180a7A2d646A2cEBd8888F7682B6BfB83aaC6B")

func packet(seq uint64, dest string) abiPacket {
	return abiPacket{Sequence: seq, SourceClient: "ethereum-1", DestClient: dest, TimeoutTimestamp: 99,
		Payloads: []abiPayload{{"transfer", "transfer", "ics20-1", "application/x-solidity-abi", []byte{0xab}}}}
}

func ackLog(t *testing.T, block uint64, dest string, seq uint64, ack string) types.Log {
	t.Helper()
	ev := RouterABI.Events["WriteAcknowledgement"]
	data, err := ev.Inputs.NonIndexed().Pack(packet(seq, dest), [][]byte{[]byte(ack)})
	if err != nil {
		t.Fatal(err)
	}
	return types.Log{Address: router, BlockNumber: block, Data: data,
		Topics: []common.Hash{ev.ID, crypto.Keccak256Hash([]byte(dest)), common.BigToHash(new(big.Int).SetUint64(seq))}}
}

func TestWrittenAckFindsTheNewestWithinTheDeployment(t *testing.T) {
	src := &fakeLogs{head: 25_000, maxRange: 3_000, logs: []types.Log{
		ackLog(t, 5_000, "client-0", 3, "stale"),
		ackLog(t, 20_000, "client-0", 3, "ack"),
		ackLog(t, 24_000, "client-0", 4, "other sequence"),
		ackLog(t, 24_500, "client-1", 3, "other client"),
	}}
	c := &Client{Logs: src, Dep: &Deployment{ICS26Router: router, DeployBlock: 4_000}}
	acks, block, err := c.WrittenAck(context.Background(), "client-0", 3)
	if err != nil {
		t.Fatal(err)
	}
	if block != 20_000 || len(acks) != 1 || string(acks[0]) != "ack" {
		t.Errorf("got %q at block %d, want [ack] at 20000", acks, block)
	}
	for _, r := range src.ranges {
		if r[0] < 4_000 {
			t.Errorf("range %v reaches below the deployment block", r)
		}
		if r[1] < 20_000 {
			t.Errorf("range %v: the scan went on past the match", r)
		}
	}
}

func TestWrittenAckNone(t *testing.T) {
	src := &fakeLogs{head: 25_000, maxRange: 3_000, logs: []types.Log{ackLog(t, 20_000, "client-0", 4, "ack")}}
	c := &Client{Logs: src, Dep: &Deployment{ICS26Router: router, DeployBlock: 4_000}}
	if _, _, err := c.WrittenAck(context.Background(), "client-0", 3); err == nil {
		t.Fatal("found an acknowledgement for a sequence without one")
	}
}

// The deployment block bounds the scan: a match below it belongs to an older
// deployment and is neither returned nor queried for.
func TestWrittenAckIgnoresAMatchBelowTheDeployment(t *testing.T) {
	src := &fakeLogs{head: 25_000, maxRange: 3_000, logs: []types.Log{ackLog(t, 3_000, "client-0", 3, "older deployment")}}
	c := &Client{Logs: src, Dep: &Deployment{ICS26Router: router, DeployBlock: 4_000}}
	if acks, block, err := c.WrittenAck(context.Background(), "client-0", 3); err == nil {
		t.Fatalf("got %q at block %d from below the deployment block", acks, block)
	}
	if len(src.ranges) == 0 {
		t.Fatal("no range was queried")
	}
	for _, r := range src.ranges {
		if r[0] < 4_000 {
			t.Errorf("range %v reaches below the deployment block", r)
		}
	}
}

func TestWrittenAckDeploymentBoundary(t *testing.T) {
	for _, tc := range []struct {
		block uint64
		found bool
	}{
		{4_000, true},  // at the deployment block: inside the scan
		{3_999, false}, // one block below it: outside
	} {
		src := &fakeLogs{head: 25_000, maxRange: 3_000, logs: []types.Log{ackLog(t, tc.block, "client-0", 3, "ack")}}
		c := &Client{Logs: src, Dep: &Deployment{ICS26Router: router, DeployBlock: 4_000}}
		acks, block, err := c.WrittenAck(context.Background(), "client-0", 3)
		if tc.found {
			if err != nil || block != tc.block || len(acks) != 1 || string(acks[0]) != "ack" {
				t.Errorf("match at %d: got %q at block %d, %v; want [ack] at %d", tc.block, acks, block, err, tc.block)
			}
		} else if err == nil {
			t.Errorf("match at %d: got %q at block %d, want none", tc.block, acks, block)
		}
	}
}

func TestSendPacketsAcrossChunks(t *testing.T) {
	ev := RouterABI.Events["SendPacket"]
	sendLog := func(block, seq uint64) types.Log {
		data, err := ev.Inputs.NonIndexed().Pack(packet(seq, "client-0"))
		if err != nil {
			t.Fatal(err)
		}
		return types.Log{Address: router, BlockNumber: block, Data: data,
			Topics: []common.Hash{ev.ID, crypto.Keccak256Hash([]byte("ethereum-1")), common.BigToHash(new(big.Int).SetUint64(seq))}}
	}
	src := &fakeLogs{maxRange: 3_000, logs: []types.Log{sendLog(4_100, 1), ackLog(t, 4_200, "client-0", 1, "not a send"), sendLog(12_000, 2)}}
	c := &Client{Logs: src, Dep: &Deployment{ICS26Router: router}}
	sent, err := c.SendPackets(context.Background(), 4_000, 12_000)
	if err != nil {
		t.Fatal(err)
	}
	if len(sent) != 2 || sent[0].Packet.Sequence != 1 || sent[0].Block != 4_100 || sent[1].Packet.Sequence != 2 || sent[1].Block != 12_000 {
		t.Fatalf("got %+v", sent)
	}
	if p := sent[1].Packet; p.SourceClient != "ethereum-1" || p.DestinationClient != "client-0" || p.TimeoutTimestamp != 99 ||
		len(p.Payloads) != 1 || p.Payloads[0].Version != "ics20-1" || string(p.Payloads[0].Value) != "\xab" {
		t.Errorf("packet decoded as %+v", p)
	}
}
