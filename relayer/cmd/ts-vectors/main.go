// Command ts-vectors records wire-encoding test vectors for the TypeScript
// relayer (allinbits/ibc-v2-ts-relayer): live beacon updates as the beacon
// API served them, and what relayer/ethgno encodes from them, so the
// TypeScript encoder can be checked byte for byte against this one.
//
// Usage: ts-vectors -beacon URL -rpc URL > vectors.json
package main

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"flag"
	"log"
	"os"
	"time"

	"github.com/gnolang/gno-eth-ibc/relayer/beacon"
	"github.com/gnolang/gno-eth-ibc/relayer/ethgno"
)

type headerVector struct {
	Update              json.RawMessage `json:"update"`
	ActiveCommittee     json.RawMessage `json:"activeCommittee"`
	IsNext              bool            `json:"isNext"`
	TrustedSlot         uint64          `json:"trustedSlot"`
	FinalizedExecHeader string          `json:"finalizedExecHeader"`
	Expected            string          `json:"expected"`
}

func main() {
	beaconURL := flag.String("beacon", "https://lodestar-sepolia.chainsafe.io", "beacon node API")
	rpcURL := flag.String("rpc", "https://ethereum-sepolia-rpc.publicnode.com", "execution JSON-RPC")
	flag.Parse()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	bc, ex := beacon.New(*beaconURL), ethgno.NewExecution(*rpcURL)

	params, err := ethgno.ReadChainParams(ctx, bc)
	check(err)
	spp := params.SlotsPerEpoch * params.EpochsPerSyncCommitteePeriod
	fin, err := bc.FinalityUpdate(ctx)
	check(err)
	period := uint64(fin.SignatureSlot) / spp
	prev, err := bc.Updates(ctx, period-1, 1)
	check(err)
	cur, err := bc.Updates(ctx, period, 1)
	check(err)
	active := *prev[0].NextSyncCommittee

	vector := func(u beacon.LightClientUpdate, trusted uint64) headerVector {
		var rlp []byte
		if u.FinalizedHeader.Execution == nil {
			h, err := ex.Header(ctx, u.FinalizedHeader.BlockHash())
			check(err)
			rlp = h.RLP
		}
		return headerVector{
			Update:              mustJSON(u),
			ActiveCommittee:     mustJSON(active),
			TrustedSlot:         trusted,
			FinalizedExecHeader: hex.EncodeToString(rlp),
			Expected:            hex.EncodeToString(ethgno.EncodeHeader(u, active, false, trusted, rlp)),
		}
	}

	proof := ethgno.StorageProof{
		AccountProof: [][]byte{{0xf8, 0x51, 0x80}, make([]byte, 300)},
		StorageProof: [][]byte{{0xe2, 0x01}},
	}
	packet := ethgno.Packet{
		Sequence: 7, SourceClient: "client-0", DestinationClient: "ethereum-1", TimeoutTimestamp: 1792078494,
		Payloads: []ethgno.Payload{{SourcePort: "transfer", DestinationPort: "transfer", Version: "ics20-1",
			Encoding: "application/x-solidity-abi", Value: []byte{0, 1, 2, 3}}},
	}
	out := map[string]any{
		"headers": []headerVector{
			vector(cur[0], uint64(cur[0].FinalizedHeader.Beacon.Slot)),
			vector(fin, uint64(cur[0].FinalizedHeader.Beacon.Slot)),
		},
		"membershipProof": map[string]any{
			"accountProof": hexAll(proof.AccountProof),
			"storageProof": hexAll(proof.StorageProof),
			"expected":     hex.EncodeToString(ethgno.EncodeMembershipProof(proof)),
		},
		"recvPacket": hex.EncodeToString(ethgno.EncodePacketMsg(packet, 11361600, nil, proof)),
		"ackPacket":  hex.EncodeToString(ethgno.EncodePacketMsg(packet, 11361600, [][]byte{[]byte(`{"result":"AQ=="}`)}, proof)),
	}
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	check(enc.Encode(out))
}

func mustJSON(v any) json.RawMessage {
	b, err := json.Marshal(v)
	check(err)
	return b
}

func hexAll(bs [][]byte) []string {
	out := make([]string, len(bs))
	for i, b := range bs {
		out[i] = hex.EncodeToString(b)
	}
	return out
}

func check(err error) {
	if err != nil {
		log.Fatal(err)
	}
}
