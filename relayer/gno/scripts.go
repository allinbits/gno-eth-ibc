package gno

import (
	"bytes"
	"encoding/hex"
	"fmt"
	"strings"
	"text/template"
)

// MsgRun scripts the relayer submits to the core realm. Bytes are passed as
// hex literals decoded at run time.

const scriptHeader = `package main

import (
	"encoding/hex"
{{range .Imports}}	"{{.}}"
{{end}})

func h(s string) []byte {
	b, err := hex.DecodeString(s)
	if err != nil {
		panic(err)
	}
	return b
}
`

// EthPlaceholderClient describes an Ethereum light client on gno that is
// created but never updated: enough for a local chain (anvil) without a
// beacon chain, where gno only sends packets. Its consensus timestamp must
// precede the timeouts of the packets sent over it.
type EthPlaceholderClient struct {
	EVMChainID uint64
	Router     [20]byte
	Timestamp  uint64 // unix seconds
}

// IBCStoreCommitmentSlot is the ERC-7201 storage slot of solidity-ibc-eureka's
// IBCStore commitments mapping (also used by gno-realms' fixtures).
const IBCStoreCommitmentSlot = "1260944489272988d9df285149b5aa1b0f48f2136d6f416159f840a3e0747600"

var createEthClientTmpl = template.Must(template.New("create").Parse(scriptHeader + `
func main(cur realm) {
	fork := func(v byte) ethereum.Fork { return ethereum.Fork{Version: [4]byte{v, 0, 0, 0}} }
	clientState := ethereum.ClientState{
		ChainID:                      {{.EVMChainID}},
		GenesisValidatorsRoot:        make([]byte, 32),
		MinSyncCommitteeParticipants: 1,
		SyncCommitteeSize:            32,
		ForkParameters: ethereum.ForkParameters{
			Altair: fork(1), Bellatrix: fork(2), Capella: fork(3), Deneb: fork(4), Electra: fork(5), Fulu: fork(6),
			Gloas: ethereum.Fork{Epoch: ethereum.FarFutureEpoch},
		},
		SecondsPerSlot:               12,
		SlotsPerEpoch:                32,
		EpochsPerSyncCommitteePeriod: 256,
		LatestSlot:                   1,
		LatestExecutionBlockNumber:   1,
		IBCContractAddress:           h("{{.Router}}"),
		IBCCommitmentSlot:            h("{{.Slot}}"),
	}
	consensusState := ethereum.ConsensusState{
		Slot:      1,
		StateRoot: make([]byte, 32),
		Timestamp: {{.Timestamp}},
		CurrentSyncCommittee: ethereum.SummarizedSyncCommittee{
			PubkeysHash:     make([]byte, 32),
			AggregatePubkey: make([]byte, 48),
		},
	}
	println(core.CreateClient(cross(cur), clientState, consensusState))
}
`))

// CreateEthPlaceholderClientScript renders the MsgRun creating the client.
func CreateEthPlaceholderClientScript(p EthPlaceholderClient) string {
	return render(createEthClientTmpl, map[string]any{
		"Imports":    []string{"gno.land/p/aib/ibc/lightclient/ethereum/v0", CoreRealm},
		"EVMChainID": p.EVMChainID,
		"Router":     hex.EncodeToString(p.Router[:]),
		"Slot":       IBCStoreCommitmentSlot,
		"Timestamp":  p.Timestamp,
	})
}

var registerTmpl = template.Must(template.New("register").Parse(scriptHeader + `
func main(cur realm) {
	core.RegisterCounterparty(cross(cur), "{{.ClientID}}", [][]byte{ {{- .Prefix -}} }, "{{.Counterparty}}")
}
`))

// RegisterCounterpartyScript renders the MsgRun registering a counterparty.
// It must be signed by the key that created the client.
func RegisterCounterpartyScript(clientID string, merklePrefix [][]byte, counterpartyClientID string) string {
	parts := make([]string, len(merklePrefix))
	for i, p := range merklePrefix {
		parts[i] = fmt.Sprintf("h(%q)", hex.EncodeToString(p))
	}
	return render(registerTmpl, map[string]any{
		"Imports":      []string{CoreRealm},
		"ClientID":     clientID,
		"Prefix":       strings.Join(parts, ", "),
		"Counterparty": counterpartyClientID,
	})
}

func render(t *template.Template, data any) string {
	var b bytes.Buffer
	if err := t.Execute(&b, data); err != nil {
		panic(err)
	}
	return b.String()
}
