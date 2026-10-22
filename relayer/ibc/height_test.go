package ibc

import "testing"

func TestParseChainID(t *testing.T) {
	for _, tc := range []struct {
		chainID string
		want    uint64
	}{
		{"gnoland-1", 1},
		{"test-ibc-1", 1},
		{"test-ibc-12", 12},
		{"a-b-c-3", 3},
		{"gnoland1", 0},
		{"dev", 0},
		{"test-chain", 0},
		{"x-0", 0},
		{"x-01", 0},
		{"-1", 0},
		{"x--1", 0},
		{"", 0},
	} {
		if got := ParseChainID(tc.chainID); got != tc.want {
			t.Errorf("ParseChainID(%q) = %d, want %d", tc.chainID, got, tc.want)
		}
	}
}
