package ethgno

import (
	"fmt"
)

// CreateClientScript is the one MsgRun the Ethereum direction still uses:
// creating a client is rare, and its states are small. Everything else goes
// through MsgCall to gno.land/r/aib/ibc/ethrelay (see wire.go).

const scriptHeader = `package main

import (
	"encoding/hex"

	ethereum "gno.land/p/aib/ibc/lightclient/ethereum/v0"
	"gno.land/p/aib/ibc/lightclient/extproof/v0"
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/r/aib/ibc/core"
)

var (
	_ = ethereum.ClientType
	_ = extproof.Proof{}
	_ = types.Height{}
)

` + Helpers

// CreateClientScript creates an Ethereum client and registers its
// counterparty: the router-side client id, under the router's empty prefix.
func CreateClientScript(clientState, consensusState, counterpartyClientID string) string {
	return scriptHeader + fmt.Sprintf(`
func main(cur realm) {
	id := core.CreateClient(cross(cur), %s, %s)
	core.RegisterCounterparty(cross(cur), id, [][]byte{{}}, %q)
	println(id)
}
`, clientState, consensusState, counterpartyClientID)
}

// Packet is an IBC v2 packet as the relayer saw it on the router.
type Packet struct {
	Sequence          uint64
	SourceClient      string
	DestinationClient string
	TimeoutTimestamp  uint64
	Payloads          []Payload
}

type Payload struct {
	SourcePort, DestinationPort, Version, Encoding string
	Value                                          []byte
}
