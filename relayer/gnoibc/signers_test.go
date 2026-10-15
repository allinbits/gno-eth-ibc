package gnoibc

import (
	"testing"

	"github.com/gnolang/gno/tm2/pkg/bft/types"
	"github.com/gnolang/gno/tm2/pkg/crypto/secp256k1"
)

func testSet(t *testing.T, powers map[string]int64) (*types.ValidatorSet, map[string]*types.Validator) {
	t.Helper()
	byName := map[string]*types.Validator{}
	var vs []*types.Validator
	for name, p := range powers {
		v := types.NewValidator(secp256k1.GenPrivKeySecp256k1([]byte(name)).PubKey(), p)
		byName[name] = v
		vs = append(vs, v)
	}
	return types.NewValidatorSet(vs), byName
}

func allSigned(vals *types.ValidatorSet) *types.Commit {
	bid := types.BlockID{Hash: make([]byte, 32), PartsHeader: types.PartSetHeader{Total: 1, Hash: make([]byte, 32)}}
	pcs := make([]*types.CommitSig, vals.Size())
	for i := range pcs {
		pcs[i] = &types.CommitSig{BlockID: bid, Height: 2, Type: types.PrecommitType}
	}
	return types.NewCommit(bid, pcs)
}

func names(vals *types.ValidatorSet, by map[string]*types.Validator, idx []int) map[string]bool {
	out := map[string]bool{}
	for _, i := range idx {
		for n, v := range by {
			if v.Address == vals.Validators[i].Address {
				out[n] = true
			}
		}
	}
	return out
}

func TestSelectSignersMinimal(t *testing.T) {
	vals, by := testSet(t, map[string]int64{"a": 30, "b": 20, "c": 10})
	idx, err := SelectSigners(allSigned(vals), vals, nil, 1, 3, false)
	if err != nil {
		t.Fatal(err)
	}
	got := names(vals, by, idx)
	// 30 + 20 = 50 > 40; 30 + 10 = 40 would not do
	if len(got) != 2 || !got["a"] || !got["b"] {
		t.Fatalf("chose %v", got)
	}
}

func TestSelectSignersMeetsTrustLevel(t *testing.T) {
	// header set: a,b,c,d at 10 each; trusted set: c (10), x (20), y (20)
	vals, by := testSet(t, map[string]int64{"a": 10, "b": 10, "c": 10, "d": 10})
	trusted, _ := testSet(t, map[string]int64{"c": 10, "x": 20, "y": 20})
	_, err := SelectSigners(allSigned(vals), vals, trusted, 1, 3, false)
	if err == nil {
		t.Fatal("c alone holds 10 of 50 trusted power, 10 <= 16: must fail")
	}
	trusted, _ = testSet(t, map[string]int64{"c": 10, "d": 10, "x": 20})
	idx, err := SelectSigners(allSigned(vals), vals, trusted, 1, 3, false)
	if err != nil {
		t.Fatal(err)
	}
	got := names(vals, by, idx)
	// trust needs > 13: c and d (20); 2/3 of 40 needs > 26: one more
	if len(got) != 3 || !got["c"] || !got["d"] {
		t.Fatalf("chose %v", got)
	}
}
