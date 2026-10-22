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
		{"x-18446744073709551615", 18446744073709551615},
	} {
		got, err := ParseChainID(tc.chainID)
		if err != nil || got != tc.want {
			t.Errorf("ParseChainID(%q) = %d, %v, want %d", tc.chainID, got, err, tc.want)
		}
	}
}

func TestParseChainIDOverflow(t *testing.T) {
	for _, id := range []string{"x-18446744073709551616", "gnoland-99999999999999999999"} {
		if got, err := ParseChainID(id); err == nil {
			t.Errorf("ParseChainID(%q) = %d, want an error", id, got)
		}
	}
}
