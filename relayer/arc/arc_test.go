package arc

import (
	"encoding/hex"
	"testing"

	"github.com/ethereum/go-ethereum/common"
)

// The precommit of validator 0xfeb2…6941 for Arc testnet block 70498732, as
// the Gno client builds it (certificate.gno, TestPrecommitSignBytes).
func TestPrecommitSignBytes(t *testing.T) {
	got := hex.EncodeToString(PrecommitSignBytes(70498732, 0,
		common.HexToHash("0x129279b48f856a98fc675cd4e9f7bbbee34673e10ddaf44044d413b8e67ce685"),
		common.HexToAddress("0xfeb2b98d614701434ea6a12ccf29e0e40ae56941")))
	want := "01acb9330400000000" + "25000000" + "2a000000" + "feb2b98d614701434ea6a12ccf29e0e40ae56941" +
		"0100000000" + "01" + "129279b48f856a98fc675cd4e9f7bbbee34673e10ddaf44044d413b8e67ce685"
	if got != want {
		t.Fatalf("got %s\nwant %s", got, want)
	}
}

func TestSlotAdd(t *testing.T) {
	if got := slotAdd(common.HexToHash("0xff"), 1); got != common.HexToHash("0x100") {
		t.Fatal(got)
	}
	max := common.HexToHash("0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff")
	if got := slotAdd(max, 2); got != common.HexToHash("0x1") {
		t.Fatal(got)
	}
}

// Every registry slot the relayer proves follows the registry's storage
// location, and the creation message names the registry it is given.
func TestRegistryLocation(t *testing.T) {
	moved := Registry{Address: RegistryAddress, StorageLocation: common.HexToHash("0x01")}
	if moved.SetSlot() != common.HexToHash("0x02") || TestnetRegistry.SetSlot() != slotAdd(RegistryStorageLocation, 1) {
		t.Fatal("set slot does not follow the storage location")
	}
	id := common.HexToHash("0x2a")
	if moved.RegistrationKeys(id)[0] == TestnetRegistry.RegistrationKeys(id)[0] {
		t.Fatal("registration slots do not follow the storage location")
	}
	msg := EncodeCreation(ClientParams{Registry: moved}, Snapshot{})
	// Five 8-byte uints, then the address blob and the location blob, each
	// a one-byte length then the bytes.
	off := 5*8 + 1 + 20 + 1
	if got := common.BytesToHash(msg[off : off+32]); got != moved.StorageLocation {
		t.Fatalf("creation names storage location %s", got)
	}
}
