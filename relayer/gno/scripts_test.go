package gno

import (
	"strings"
	"testing"
)

func TestScripts(t *testing.T) {
	c := CreateEthPlaceholderClientScript(EthPlaceholderClient{EVMChainID: 31337, Timestamp: 5})
	for _, want := range []string{"ChainID:                      31337", "Gloas: ethereum.Fork{Epoch: ethereum.FarFutureEpoch}", "Timestamp: 5", `"gno.land/r/aib/ibc/core"`} {
		if !strings.Contains(c, want) {
			t.Errorf("create script lacks %q", want)
		}
	}
	r := RegisterCounterpartyScript("ethereum-1", [][]byte{{}}, "client-0")
	if !strings.Contains(r, `core.RegisterCounterparty(cross(cur), "ethereum-1", [][]byte{h("")}, "client-0")`) {
		t.Errorf("register script:\n%s", r)
	}
}
