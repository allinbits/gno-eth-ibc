// Package arc reads what the gno.land Arc light client verifies from Arc's
// JSON-RPC: commit certificates (arc_getCertificate), RLP block headers, and
// eth_getProof proofs of the validator registry and of the ICS26 router.
//
// Arc's public RPC nodes serve eth_getProof for the latest block only, so a
// snapshot reads every proof at "latest" and identifies the block those
// proofs are into by its state root.
package arc

import (
	"context"
	"encoding/base64"
	"encoding/binary"
	"fmt"
	"math/big"
	"time"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/common/hexutil"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/ethclient"
	"github.com/ethereum/go-ethereum/rlp"
	"github.com/ethereum/go-ethereum/rpc"
)

// Testnet defaults.
const (
	TestnetChainID   = 5042002
	TestnetCertRPC   = "https://rpc.blockdaemon.testnet.arc.io"
	TestnetProofRPC  = "https://rpc.blockdaemon.testnet.arc.io"
	maxProofKeys     = 64
	snapshotAttempts = 20
)

var (
	// RegistryAddress is the ValidatorRegistry proxy.
	RegistryAddress = common.HexToAddress("0x3600000000000000000000000000000000000002")
	// RegistryStorageLocation is its ERC-7201 storage base slot.
	RegistryStorageLocation = common.HexToHash("0xb58da0dce03316992faea3e12c60705b8ac05a309e27e3bc8421e5b271c9d200")
	// ImplementationSlot is the ERC-1967 implementation slot of its proxy,
	// whose value the client pins at creation.
	ImplementationSlot = common.HexToHash("0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc")
)

// Client reads Arc. Certificates come from certRPC (a node run with
// --enable-arc-rpc), headers and proofs from proofRPC (one serving
// eth_getProof).
type Client struct {
	cert  *rpc.Client
	proof *rpc.Client
	eth   *ethclient.Client
}

// Dial connects to both endpoints (they may be the same).
func Dial(ctx context.Context, certURL, proofURL string) (*Client, error) {
	cert, err := rpc.DialContext(ctx, certURL)
	if err != nil {
		return nil, err
	}
	proof, err := rpc.DialContext(ctx, proofURL)
	if err != nil {
		return nil, err
	}
	return &Client{cert: cert, proof: proof, eth: ethclient.NewClient(proof)}, nil
}

// Signature is one validator's precommit signature.
type Signature struct {
	Address   common.Address
	Signature []byte
}

// Certificate is a Malachite commit certificate.
type Certificate struct {
	Height     uint64
	Round      uint32
	BlockHash  common.Hash
	Signatures []Signature
}

// Certificate returns the commit certificate of height, waiting for it.
func (c *Client) Certificate(ctx context.Context, height uint64) (Certificate, error) {
	var raw struct {
		Height     uint64      `json:"height"`
		Round      uint32      `json:"round"`
		BlockHash  common.Hash `json:"block_hash"`
		Signatures []struct {
			Address   common.Address `json:"address"`
			Signature string         `json:"signature"`
		} `json:"signatures"`
	}
	var err error
	for i := 0; i < 40; i++ {
		if err = c.cert.CallContext(ctx, &raw, "arc_getCertificate", height); err == nil && raw.Height == height {
			break
		}
		select {
		case <-ctx.Done():
			return Certificate{}, ctx.Err()
		case <-time.After(250 * time.Millisecond):
		}
	}
	if err != nil {
		return Certificate{}, fmt.Errorf("arc_getCertificate(%d): %w", height, err)
	}
	if raw.Height != height {
		return Certificate{}, fmt.Errorf("arc_getCertificate(%d): no certificate yet", height)
	}
	out := Certificate{Height: raw.Height, Round: raw.Round, BlockHash: raw.BlockHash}
	for _, s := range raw.Signatures {
		sig, err := base64.StdEncoding.DecodeString(s.Signature)
		if err != nil || len(sig) != 64 {
			return Certificate{}, fmt.Errorf("certificate %d: malformed signature of %s", height, s.Address)
		}
		out.Signatures = append(out.Signatures, Signature{Address: s.Address, Signature: sig})
	}
	return out, nil
}

// Header returns block n's header and its RLP encoding, checked against the
// block hash the node reports.
func (c *Client) Header(ctx context.Context, n uint64) (*types.Header, []byte, error) {
	h, err := c.eth.HeaderByNumber(ctx, new(big.Int).SetUint64(n))
	if err != nil {
		return nil, nil, fmt.Errorf("header %d: %w", n, err)
	}
	bz, err := rlp.EncodeToBytes(h)
	if err != nil {
		return nil, nil, err
	}
	var reported struct {
		Hash common.Hash `json:"hash"`
	}
	if err := c.proof.CallContext(ctx, &reported, "eth_getBlockByNumber", hexutil.EncodeUint64(n), false); err != nil {
		return nil, nil, err
	}
	if crypto.Keccak256Hash(bz) != reported.Hash {
		return nil, nil, fmt.Errorf("header %d: RLP re-encoding hashes to %s, not %s", n, crypto.Keccak256Hash(bz), reported.Hash)
	}
	return h, bz, nil
}

// LatestNumber is the latest block number.
func (c *Client) LatestNumber(ctx context.Context) (uint64, error) {
	return c.eth.BlockNumber(ctx)
}

type accountResult struct {
	AccountProof []hexutil.Bytes `json:"accountProof"`
	StorageHash  common.Hash     `json:"storageHash"`
	StorageProof []struct {
		Key   hexutil.Bytes   `json:"key"`
		Value *hexutil.Big    `json:"value"`
		Proof []hexutil.Bytes `json:"proof"`
	} `json:"storageProof"`
}

func (r accountResult) stateRoot() common.Hash {
	if len(r.AccountProof) == 0 {
		return common.Hash{}
	}
	return crypto.Keccak256Hash(r.AccountProof[0])
}

func (c *Client) getProof(ctx context.Context, account common.Address, keys []common.Hash) (accountResult, error) {
	ks := make([]string, len(keys))
	for i, k := range keys {
		ks[i] = k.Hex()
	}
	var r accountResult
	err := c.proof.CallContext(ctx, &r, "eth_getProof", account, ks, "latest")
	return r, err
}

// Proof is an eth_getProof proof: the account's proof and the union of its
// storage proofs, each node once.
type Proof struct {
	AccountProof [][]byte
	StorageRoot  common.Hash
	Nodes        [][]byte
	Values       map[common.Hash]common.Hash
}

// proveLatest proves keys of account at the latest block, as a pooled
// proof, requiring every call to land in state root root (zero: the first
// call's).
func (c *Client) proveLatest(ctx context.Context, account common.Address, keys []common.Hash, root common.Hash) (Proof, common.Hash, error) {
	p := Proof{Values: map[common.Hash]common.Hash{}}
	seen := map[common.Hash]bool{}
	for start := 0; start == 0 || start < len(keys); start += maxProofKeys {
		end := min(start+maxProofKeys, len(keys))
		r, err := c.getProof(ctx, account, keys[start:end])
		if err != nil {
			return Proof{}, common.Hash{}, err
		}
		if root == (common.Hash{}) {
			root = r.stateRoot()
		} else if r.stateRoot() != root {
			return Proof{}, common.Hash{}, errMoved
		}
		if p.AccountProof == nil {
			p.AccountProof = bytesOf(r.AccountProof)
			p.StorageRoot = r.StorageHash
		}
		for _, sp := range r.StorageProof {
			var v common.Hash
			if sp.Value != nil {
				v = common.BigToHash(sp.Value.ToInt())
			}
			p.Values[common.BytesToHash(sp.Key)] = v
			for _, n := range sp.Proof {
				h := crypto.Keccak256Hash(n)
				if !seen[h] {
					seen[h] = true
					p.Nodes = append(p.Nodes, n)
				}
			}
		}
		if len(keys) == 0 {
			break
		}
	}
	return p, root, nil
}

var errMoved = fmt.Errorf("the latest block moved between proofs")

// Snapshot is a block B and the proofs the client verifies into its state:
// the registry's (and, when its storage root is not knownRegistryRoot, the
// set it holds), and the router's commitments at routerKeys.
type Snapshot struct {
	Number      uint64
	Header      *types.Header
	HeaderRLP   []byte
	Registry    Proof
	SetIncluded bool
	Router      Proof
}

// LatestSnapshot reads a Snapshot of the latest block, retrying while the
// chain moves under the proof calls.
func (c *Client) LatestSnapshot(ctx context.Context, knownRegistryRoot common.Hash, router common.Address, routerKeys []common.Hash) (Snapshot, error) {
	var lastErr error
	for i := 0; i < snapshotAttempts; i++ {
		s, err := c.snapshot(ctx, knownRegistryRoot, router, routerKeys)
		if err == nil {
			return s, nil
		}
		lastErr = err
		if err != errMoved {
			return Snapshot{}, err
		}
	}
	return Snapshot{}, fmt.Errorf("snapshot: %w", lastErr)
}

func (c *Client) snapshot(ctx context.Context, knownRegistryRoot common.Hash, router common.Address, routerKeys []common.Hash) (Snapshot, error) {
	s := Snapshot{}
	reg, root, err := c.proveLatest(ctx, RegistryAddress, nil, common.Hash{})
	if err != nil {
		return Snapshot{}, err
	}
	if reg.StorageRoot != knownRegistryRoot {
		reg, err = c.proveSet(ctx, root)
		if err != nil {
			return Snapshot{}, err
		}
		s.SetIncluded = true
	}
	s.Registry = reg
	if len(routerKeys) > 0 {
		s.Router, _, err = c.proveLatest(ctx, router, routerKeys, root)
		if err != nil {
			return Snapshot{}, err
		}
	}
	n, h, bz, err := c.findByStateRoot(ctx, root)
	if err != nil {
		return Snapshot{}, err
	}
	s.Number, s.Header, s.HeaderRLP = n, h, bz
	return s, nil
}

// proveSet proves every registry slot the client reads for the active set,
// in state root root: the proxy's implementation, the set's length, its
// registration ids, and each registration's status, key length, key and
// power.
func (c *Client) proveSet(ctx context.Context, root common.Hash) (Proof, error) {
	setSlot := slotAdd(RegistryStorageLocation, 1)
	p, _, err := c.proveLatest(ctx, RegistryAddress, []common.Hash{setSlot}, root)
	if err != nil {
		return Proof{}, err
	}
	n := p.Values[setSlot].Big().Uint64()
	if n > 256 {
		return Proof{}, fmt.Errorf("registry holds %d active registrations, more than the client reads", n)
	}
	values := crypto.Keccak256Hash(setSlot[:])
	keys := []common.Hash{ImplementationSlot, setSlot}
	for i := uint64(0); i < n; i++ {
		keys = append(keys, slotAdd(values, i))
	}
	p, _, err = c.proveLatest(ctx, RegistryAddress, keys, root)
	if err != nil {
		return Proof{}, err
	}
	for i := uint64(0); i < n; i++ {
		id := p.Values[slotAdd(values, i)]
		entry := crypto.Keccak256Hash(id[:], RegistryStorageLocation[:])
		keyLen := slotAdd(entry, 1)
		keys = append(keys, entry, keyLen, crypto.Keccak256Hash(keyLen[:]), slotAdd(entry, 2))
	}
	p, _, err = c.proveLatest(ctx, RegistryAddress, keys, root)
	return p, err
}

// findByStateRoot finds the recent block whose state root is root.
func (c *Client) findByStateRoot(ctx context.Context, root common.Hash) (uint64, *types.Header, []byte, error) {
	latest, err := c.LatestNumber(ctx)
	if err != nil {
		return 0, nil, nil, err
	}
	for n := latest + 2; n+16 > latest+2 && n > 0; n-- {
		h, bz, err := c.Header(ctx, n)
		if err != nil {
			continue // not produced yet
		}
		if h.Root == root {
			return n, h, bz, nil
		}
	}
	return 0, nil, nil, fmt.Errorf("no recent block has state root %s", root)
}

func bytesOf(bs []hexutil.Bytes) [][]byte {
	out := make([][]byte, len(bs))
	for i, b := range bs {
		out[i] = b
	}
	return out
}

// slotAdd is s+n modulo 2^256.
func slotAdd(s common.Hash, n uint64) common.Hash {
	v := new(big.Int).SetBytes(s[:])
	v.Add(v, new(big.Int).SetUint64(n))
	v.Mod(v, new(big.Int).Lsh(big.NewInt(1), 256))
	return common.BigToHash(v)
}

// PrecommitSignBytes is what an Arc validator signs for a precommit (see the
// Gno client's certificate.gno).
func PrecommitSignBytes(height uint64, round uint32, blockHash common.Hash, addr common.Address) []byte {
	b := []byte{1}
	b = binary.LittleEndian.AppendUint64(b, height)
	b = binary.LittleEndian.AppendUint32(b, 37)
	b = binary.LittleEndian.AppendUint32(b, 42)
	b = append(b, addr[:]...)
	b = append(b, 1)
	b = binary.LittleEndian.AppendUint32(b, round)
	b = append(b, 1)
	return append(b, blockHash[:]...)
}
