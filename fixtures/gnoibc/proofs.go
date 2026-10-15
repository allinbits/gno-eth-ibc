package gnoibc

import (
	"bytes"
	"fmt"

	ics23 "github.com/cosmos/ics23/go"
	"github.com/gnolang/gno/tm2/pkg/bptree"
	"github.com/gnolang/gno/tm2/pkg/crypto/merkle"
	storebptree "github.com/gnolang/gno/tm2/pkg/store/bptree"
	"github.com/gnolang/gno/tm2/pkg/store/types"
)

// The ABI proof format carries only the leaf prefix of each LeafOp and the
// prefix/suffix of each InnerOp: hash, prehash and length operations are
// fixed by the ProofSpec the contract verifies against. ICS23 itself rejects
// a proof whose ops differ from its spec, so dropping them loses nothing;
// convertExist refuses such a proof up front instead.

func convertExist(spec *ics23.ProofSpec, p *ics23.ExistenceProof) (ExistenceProof, error) {
	if p == nil {
		return ExistenceProof{Path: []InnerOp{}}, nil
	}
	leaf := p.GetLeaf()
	if leaf == nil {
		return ExistenceProof{}, fmt.Errorf("existence proof has no leaf op")
	}
	ls := spec.LeafSpec
	if leaf.Hash != ls.Hash || leaf.PrehashKey != ls.PrehashKey || leaf.PrehashValue != ls.PrehashValue || leaf.Length != ls.Length {
		return ExistenceProof{}, fmt.Errorf("leaf op does not match spec")
	}
	out := ExistenceProof{Key: p.Key, Value: p.Value, LeafPrefix: leaf.Prefix, Path: make([]InnerOp, len(p.Path))}
	for i, in := range p.Path {
		if in.Hash != spec.InnerSpec.Hash {
			return ExistenceProof{}, fmt.Errorf("inner op %d hash does not match spec", i)
		}
		out.Path[i] = InnerOp{Prefix: nz(in.Prefix), Suffix: nz(in.Suffix)}
	}
	return out, nil
}

// EncodeExistenceProof converts a single ICS23 existence proof checked against spec.
func EncodeExistenceProof(spec *ics23.ProofSpec, p *ics23.ExistenceProof) (ExistenceProof, error) {
	if p == nil {
		return ExistenceProof{}, fmt.Errorf("nil existence proof")
	}
	return convertExist(spec, p)
}

// EncodeNonExistenceProof converts a single ICS23 non-existence proof checked against spec.
func EncodeNonExistenceProof(spec *ics23.ProofSpec, p *ics23.NonExistenceProof) (NonExistenceProof, error) {
	out := NonExistenceProof{Key: p.Key}
	var err error
	if out.Left, err = convertExist(spec, p.Left); err != nil {
		return out, err
	}
	out.Right, err = convertExist(spec, p.Right)
	return out, err
}

func nz(b []byte) []byte {
	if b == nil {
		return []byte{}
	}
	return b
}

func decodeOp(op merkle.ProofOp, wantType string) (*ics23.CommitmentProof, error) {
	if op.Type != wantType {
		return nil, fmt.Errorf("proof op type %q, want %q", op.Type, wantType)
	}
	cp := &ics23.CommitmentProof{}
	if err := cp.Unmarshal(op.Data); err != nil {
		return nil, err
	}
	return cp, nil
}

// EncodeMembershipProof converts the two ProofOps returned by an ABCI
// "/<store>/key" query with prove=true (ics23:bptree then ics23:simple).
func EncodeMembershipProof(ops []merkle.ProofOp) (MembershipProof, error) {
	var out MembershipProof
	if len(ops) != 2 {
		return out, fmt.Errorf("expected 2 proof ops, got %d", len(ops))
	}
	store, err := decodeOp(ops[0], storebptree.ProofOpBptreeCommitment)
	if err != nil {
		return out, err
	}
	root, err := decodeOp(ops[1], types.ProofOpSimpleMerkleCommitment)
	if err != nil {
		return out, err
	}
	if store.GetExist() == nil || root.GetExist() == nil {
		return out, fmt.Errorf("membership needs two existence proofs")
	}
	if out.StoreProof, err = convertExist(bptree.BptreeSpec, store.GetExist()); err != nil {
		return out, err
	}
	if out.RootProof, err = convertExist(ics23.TendermintSpec, root.GetExist()); err != nil {
		return out, err
	}
	return out, nil
}

// EncodeNonMembershipProof converts the ProofOps of an absent key.
func EncodeNonMembershipProof(ops []merkle.ProofOp) (NonMembershipProof, error) {
	var out NonMembershipProof
	if len(ops) != 2 {
		return out, fmt.Errorf("expected 2 proof ops, got %d", len(ops))
	}
	store, err := decodeOp(ops[0], storebptree.ProofOpBptreeCommitment)
	if err != nil {
		return out, err
	}
	root, err := decodeOp(ops[1], types.ProofOpSimpleMerkleCommitment)
	if err != nil {
		return out, err
	}
	ne := store.GetNonexist()
	if ne == nil || root.GetExist() == nil {
		return out, fmt.Errorf("non-membership needs a non-existence then an existence proof")
	}
	out.StoreProof.Key = ne.Key
	if out.StoreProof.Left, err = convertExist(bptree.BptreeSpec, ne.Left); err != nil {
		return out, err
	}
	if out.StoreProof.Right, err = convertExist(bptree.BptreeSpec, ne.Right); err != nil {
		return out, err
	}
	if out.RootProof, err = convertExist(ics23.TendermintSpec, root.GetExist()); err != nil {
		return out, err
	}
	if !bytes.Equal(out.StoreProof.Key, ops[0].Key) {
		return out, fmt.Errorf("non-existence proof key mismatch")
	}
	return out, nil
}
