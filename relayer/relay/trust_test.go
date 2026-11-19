package relay

import (
	"bytes"
	"testing"
	"time"

	"github.com/gnolang/gno/tm2/pkg/bft/types"
)

func TestTrustedStateRevision(t *testing.T) {
	app := bytes.Repeat([]byte{0xaa}, 32)
	next := bytes.Repeat([]byte{0xbb}, 32)
	at := time.Unix(1_700_000_000, 5)
	for _, tc := range []struct {
		chainID string
		want    uint64
	}{
		{"test-ibc-1", 1},
		{"gnoland-1", 1},
		{"gnoland1", 0},
		{"dev", 0},
		{"x-18446744073709551615", 18446744073709551615},
	} {
		sh := &types.SignedHeader{Header: &types.Header{
			ChainID: tc.chainID, Height: 42, Time: at, AppHash: app, NextValidatorsHash: next,
		}}
		cs, cons, err := trustedState(sh, TrustOptions{TrustingPeriod: 2 * time.Hour, MaxClockDrift: 30 * time.Second})
		if err != nil {
			t.Fatalf("%s: %v", tc.chainID, err)
		}
		if cs.RevisionNumber != tc.want {
			t.Errorf("%s: revision %d, want %d", tc.chainID, cs.RevisionNumber, tc.want)
		}
		if cs.ChainId != tc.chainID || cs.LatestHeight != 42 || cs.TrustingPeriod != 7200 || cs.MaxClockDrift != 30 {
			t.Errorf("%s: client state %+v", tc.chainID, cs)
		}
		if cons.Timestamp != uint64(at.UnixNano()) || !bytes.Equal(cons.AppHash[:], app) || !bytes.Equal(cons.NextValidatorsHash[:], next) {
			t.Errorf("%s: consensus state %+v", tc.chainID, cons)
		}
	}
}

func TestTrustedStateRejectsShortHashes(t *testing.T) {
	sh := &types.SignedHeader{Header: &types.Header{ChainID: "test-ibc-1", Height: 1, AppHash: []byte{1}, NextValidatorsHash: bytes.Repeat([]byte{2}, 32)}}
	if _, _, err := trustedState(sh, TrustOptions{}); err == nil {
		t.Fatal("a 1-byte app hash was accepted")
	}
}

func TestTrustedStateRejectsAnOverflowingRevision(t *testing.T) {
	sh := &types.SignedHeader{Header: &types.Header{ChainID: "x-18446744073709551616", Height: 1,
		AppHash: bytes.Repeat([]byte{1}, 32), NextValidatorsHash: bytes.Repeat([]byte{2}, 32)}}
	if cs, _, err := trustedState(sh, TrustOptions{}); err == nil {
		t.Fatalf("an overflowing revision was trusted at revision %d", cs.RevisionNumber)
	}
}
