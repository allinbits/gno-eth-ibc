// Command arc-ts-vectors records wire-encoding test vectors of the gno.land
// Arc light client for the TypeScript relayer (allinbits/ibc-v2-ts-relayer):
// fixed inputs and what relayer/arc encodes from them, so that the
// TypeScript encoders can be checked byte for byte against these. It reads
// no network.
//
// Usage: arc-ts-vectors > arc-vectors.json
package main

import (
	"encoding/hex"
	"encoding/json"
	"log"
	"os"

	"github.com/ethereum/go-ethereum/common"

	"github.com/gnolang/gno-eth-ibc/relayer/arc"
	"github.com/gnolang/gno-eth-ibc/relayer/ethgno"
)

type precommit struct {
	Height    uint64 `json:"height"`
	Round     uint32 `json:"round"`
	BlockHash string `json:"blockHash"`
	Address   string `json:"address"`
	Expected  string `json:"expected"`
}

type signature struct {
	Address   string `json:"address"`
	Signature string `json:"signature"`
}

type certificate struct {
	Height     uint64      `json:"height"`
	Round      uint32      `json:"round"`
	BlockHash  string      `json:"blockHash"`
	Signatures []signature `json:"signatures"`
}

type snapshot struct {
	HeaderRLP    string   `json:"headerRlp"`
	AccountProof []string `json:"accountProof"`
	Nodes        []string `json:"nodes"`
	SetIncluded  bool     `json:"setIncluded"`
}

type headerVector struct {
	TrustedHeight uint64      `json:"trustedHeight"`
	Certificate   certificate `json:"certificate"`
	Certified     string      `json:"certified"`
	Snapshot      snapshot    `json:"snapshot"`
	Expected      string      `json:"expected"`
}

func main() {
	fill := func(n int, b byte) []byte {
		out := make([]byte, n)
		for i := range out {
			out[i] = b + byte(i)
		}
		return out
	}
	cert := arc.Certificate{
		Height:    70498733,
		Round:     2,
		BlockHash: common.BytesToHash(fill(32, 0x10)),
		Signatures: []arc.Signature{
			{Address: common.BytesToAddress(fill(20, 0x40)), Signature: fill(64, 0x80)},
			{Address: common.BytesToAddress(fill(20, 0x50)), Signature: fill(64, 0x90)},
		},
	}
	registry := arc.Proof{
		AccountProof: [][]byte{fill(83, 0xf8), fill(300, 0x01)},
		Nodes:        [][]byte{fill(40, 0xe2), fill(130, 0x03), fill(1, 0x80)},
	}
	withSet := arc.Snapshot{Number: 70498732, HeaderRLP: fill(600, 0xf9), Registry: registry, SetIncluded: true}
	withoutSet := withSet
	withoutSet.SetIncluded = false
	router := arc.Proof{AccountProof: [][]byte{fill(83, 0xf8)}, Nodes: [][]byte{fill(70, 0xe4), fill(33, 0x20)}}
	withSet.Router = router

	header := func(s arc.Snapshot) headerVector {
		v := headerVector{
			TrustedHeight: 70498000,
			Certificate:   certificate{Height: cert.Height, Round: cert.Round, BlockHash: cert.BlockHash.Hex()},
			Certified:     hex.EncodeToString(fill(610, 0xf9)),
			Snapshot: snapshot{
				HeaderRLP: hex.EncodeToString(s.HeaderRLP), AccountProof: hexAll(s.Registry.AccountProof),
				Nodes: hexAll(s.Registry.Nodes), SetIncluded: s.SetIncluded,
			},
			Expected: hex.EncodeToString(arc.EncodeHeader(70498000, cert, fill(610, 0xf9), s)),
		}
		for _, sig := range cert.Signatures {
			v.Certificate.Signatures = append(v.Certificate.Signatures, signature{Address: sig.Address.Hex(), Signature: hex.EncodeToString(sig.Signature)})
		}
		return v
	}

	params := arc.ClientParams{
		ChainID: arc.TestnetChainID, TrustingPeriod: 14 * 24 * 3600, MaxClockDrift: 90,
		TrustNumerator: 1, TrustDenominator: 3,
		Router:         common.HexToAddress("0x00000000000000000000000000000000000000aa"),
		CommitmentSlot: common.BytesToHash(ethgno.IBCStoreCommitmentSlot),
		Registry:       arc.TestnetRegistry,
	}

	ids := []common.Hash{common.HexToHash("0x01"), common.HexToHash("0x2a"), common.BytesToHash(fill(32, 0xc0))}
	registrations := map[string][]string{}
	for _, id := range ids {
		registrations[id.Hex()] = hashesHex(arc.TestnetRegistry.RegistrationKeys(id))
	}

	path := []byte("client-0\x01\x00\x00\x00\x00\x00\x00\x00\x07")
	key := common.BytesToHash(ethgno.CommitmentSlot(path, ethgno.IBCStoreCommitmentSlot))
	packet := ethgno.Packet{
		Sequence: 7, SourceClient: "client-0", DestinationClient: "arc-1", TimeoutTimestamp: 1792078494,
		Payloads: []ethgno.Payload{{SourcePort: "transfer", DestinationPort: "transfer", Version: "ics20-1",
			Encoding: "application/x-solidity-abi", Value: []byte{0, 1, 2, 3}}},
	}
	proof := ethgno.StorageProof{AccountProof: router.AccountProof, StorageProof: router.Nodes}

	out := map[string]any{
		"precommit": precommit{
			Height: 70498732, Round: 0,
			BlockHash: "0x129279b48f856a98fc675cd4e9f7bbbee34673e10ddaf44044d413b8e67ce685",
			Address:   "0xfeb2b98d614701434ea6a12ccf29e0e40ae56941",
			Expected: hex.EncodeToString(arc.PrecommitSignBytes(70498732, 0,
				common.HexToHash("0x129279b48f856a98fc675cd4e9f7bbbee34673e10ddaf44044d413b8e67ce685"),
				common.HexToAddress("0xfeb2b98d614701434ea6a12ccf29e0e40ae56941"))),
		},
		"headers": []headerVector{header(withSet), header(withoutSet)},
		"creation": map[string]any{
			"chainId": params.ChainID, "trustingPeriod": params.TrustingPeriod, "maxClockDrift": params.MaxClockDrift,
			"trustNumerator": params.TrustNumerator, "trustDenominator": params.TrustDenominator,
			"router": params.Router.Hex(), "commitmentSlot": params.CommitmentSlot.Hex(),
			"snapshot": snapshot{
				HeaderRLP: hex.EncodeToString(withSet.HeaderRLP), AccountProof: hexAll(registry.AccountProof),
				Nodes: hexAll(registry.Nodes), SetIncluded: true,
			},
			"expected": hex.EncodeToString(arc.EncodeCreation(params, withSet)),
		},
		"slots": map[string]any{
			"setSlot":       arc.TestnetRegistry.SetSlot().Hex(),
			"setKeys3":      hashesHex(arc.TestnetRegistry.SetKeys(3)),
			"registrations": registrations,
		},
		"routerProof": map[string]any{
			"accountProof": hexAll(router.AccountProof),
			"nodes":        hexAll(router.Nodes),
			"expected":     hex.EncodeToString(arc.RouterProof(withSet)),
		},
		"recvPacket": map[string]any{
			"path":           hex.EncodeToString(path),
			"commitmentSlot": key.Hex(),
			"proofHeight":    withSet.Number,
			"expected":       hex.EncodeToString(ethgno.EncodePacketMsg(packet, withSet.Number, nil, proof)),
		},
	}
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	if err := enc.Encode(out); err != nil {
		log.Fatal(err)
	}
}

func hexAll(bs [][]byte) []string {
	out := make([]string, len(bs))
	for i, b := range bs {
		out[i] = hex.EncodeToString(b)
	}
	return out
}

func hashesHex(hs []common.Hash) []string {
	out := make([]string, len(hs))
	for i, h := range hs {
		out[i] = h.Hex()
	}
	return out
}
