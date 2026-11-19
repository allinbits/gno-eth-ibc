package arc

import (
	"github.com/ethereum/go-ethereum/common"

	"github.com/gnolang/gno-eth-ibc/relayer/ethgno"
)

// ClientParams configures a new gno.land Arc client.
type ClientParams struct {
	ChainID          uint64
	TrustingPeriod   uint64 // seconds
	MaxClockDrift    uint64 // seconds
	TrustNumerator   uint64
	TrustDenominator uint64
	Router           common.Address
	CommitmentSlot   common.Hash
}

// EncodeCreation is the wire creation message of the gno.land Arc client
// (arc.DecodeCreation): the client parameters and snapshot s of its first
// trusted block, whose registry proof must include the set.
func EncodeCreation(p ClientParams, s Snapshot) []byte {
	w := &ethgno.Writer{}
	w.Uint(p.ChainID).Uint(p.TrustingPeriod).Uint(p.MaxClockDrift).Uint(p.TrustNumerator).Uint(p.TrustDenominator)
	w.Blob(RegistryAddress[:]).Blob(RegistryStorageLocation[:]).Blob(p.Router[:]).Blob(p.CommitmentSlot[:])
	w.Blob(s.HeaderRLP).Blobs(s.Registry.AccountProof).Blobs(s.Registry.Nodes)
	return w.Bytes()
}

// EncodeHeader is the wire Header (arc.DecodeHeader) moving a client trusting
// trustedHeight to snapshot s's block, certified by cert, the certificate of
// the next block, whose RLP header is certified.
func EncodeHeader(trustedHeight uint64, cert Certificate, certified []byte, s Snapshot) []byte {
	w := &ethgno.Writer{}
	w.Uint(trustedHeight).Uint(cert.Height).Uint(uint64(cert.Round)).Blob(cert.BlockHash[:])
	w.Uvarint(uint64(len(cert.Signatures)))
	for _, sig := range cert.Signatures {
		w.Blob(sig.Address[:]).Blob(sig.Signature)
	}
	w.Blob(certified).Blob(s.HeaderRLP).Blobs(s.Registry.AccountProof)
	if s.SetIncluded {
		w.Blobs(s.Registry.Nodes)
	} else {
		w.Blobs(nil)
	}
	return w.Bytes()
}

// RouterProof is the wire ethereum.MembershipProof of the router commitment
// at key in snapshot s: its account proof and the pooled storage nodes,
// which hold the key's path.
func RouterProof(s Snapshot) []byte {
	w := &ethgno.Writer{}
	return w.Blobs(s.Router.AccountProof).Blobs(s.Router.Nodes).Bytes()
}
