package relay

import (
	"strings"
	"testing"

	"github.com/gnolang/gno-eth-ibc/relayer/ibc"
)

func TestAcknowledgementScript(t *testing.T) {
	w := WrittenAck{
		Packet: ibc.Packet{Sequence: 7, SourceClient: "ethereum-1", DestinationClient: "client-0", TimeoutTimestamp: 99,
			Payloads: []ibc.Payload{{SourcePort: "transfer", DestinationPort: "transfer", Version: "ics20-1", Encoding: "application/x-solidity-abi", Value: []byte{0xab}}}},
		Acks: [][]byte{[]byte(`{"result":"AQ=="}`)},
	}
	src := AcknowledgementScript(w, "ethereum.MembershipProof{}", ibc.Height{RevisionHeight: 42}, nil)
	for _, want := range []string{
		`core.Acknowledgement(cross(cur), types.MsgAcknowledgement{`,
		`types.Packet{Sequence: 7, SourceClient: "ethereum-1", DestinationClient: "client-0", TimeoutTimestamp: 99,`,
		`Value: h("ab")`,
		`AppAcknowledgements: [][]byte{h("7b22726573756c74223a2241513d3d227d")}`,
		`ProofHeight: types.NewHeight(0, 42)`,
		`Ext: extproof.Proof{Data: ethereum.MembershipProof{}}`,
	} {
		if !strings.Contains(src, want) {
			t.Errorf("script lacks %q:\n%s", want, src)
		}
	}
}
