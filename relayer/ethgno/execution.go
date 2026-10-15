package ethgno

import (
	"bytes"
	"context"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"strings"

	"golang.org/x/crypto/sha3"
)

// Execution is a minimal Ethereum JSON-RPC client for the two calls the
// light client needs: block headers and storage proofs.
type Execution struct {
	URL  string
	HTTP *http.Client
}

func NewExecution(url string) *Execution { return &Execution{URL: url, HTTP: http.DefaultClient} }

func (e *Execution) call(ctx context.Context, method string, params []any, out any) error {
	body, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": 1, "method": method, "params": params})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, e.URL, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	res, err := e.HTTP.Do(req)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	raw, err := io.ReadAll(res.Body)
	if err != nil {
		return err
	}
	var resp struct {
		Result json.RawMessage
		Error  *struct {
			Code    int
			Message string
		}
	}
	if err := json.Unmarshal(raw, &resp); err != nil {
		return fmt.Errorf("%s: %w: %s", method, err, raw)
	}
	if resp.Error != nil {
		return fmt.Errorf("%s: %d %s", method, resp.Error.Code, resp.Error.Message)
	}
	return json.Unmarshal(resp.Result, out)
}

// headerFields lists the execution header fields in RLP order. Each fork
// appends fields; a field the node omits ends the header.
var headerFields = []struct {
	name   string
	number bool
}{
	{"parentHash", false}, {"sha3Uncles", false}, {"miner", false}, {"stateRoot", false},
	{"transactionsRoot", false}, {"receiptsRoot", false}, {"logsBloom", false},
	{"difficulty", true}, {"number", true}, {"gasLimit", true}, {"gasUsed", true},
	{"timestamp", true}, {"extraData", false}, {"mixHash", false}, {"nonce", false},
	{"baseFeePerGas", true}, {"withdrawalsRoot", false}, {"blobGasUsed", true},
	{"excessBlobGas", true}, {"parentBeaconBlockRoot", false}, {"requestsHash", false},
	{"blockAccessListHash", false}, {"slotNumber", true},
}

// ExecHeader is an execution block header and the fields the client reads.
type ExecHeader struct {
	RLP       []byte
	Number    uint64
	Timestamp uint64
	StateRoot []byte
}

// Header returns the execution block header with the given hash, its RLP
// encoding checked against that hash.
func (e *Execution) Header(ctx context.Context, blockHash string) (ExecHeader, error) {
	var block map[string]any
	if err := e.call(ctx, "eth_getBlockByHash", []any{blockHash, false}, &block); err != nil {
		return ExecHeader{}, err
	}
	if block == nil {
		return ExecHeader{}, fmt.Errorf("block %s not found", blockHash)
	}
	var items [][]byte
	for _, f := range headerFields {
		v, ok := block[f.name].(string)
		if !ok {
			break
		}
		b, err := hexBytes(v)
		if err != nil {
			return ExecHeader{}, fmt.Errorf("%s: %w", f.name, err)
		}
		if f.number {
			b = new(big.Int).SetBytes(b).Bytes() // minimal big-endian
		}
		items = append(items, rlpString(b))
	}
	enc := rlpList(items)
	if got := "0x" + hex.EncodeToString(keccak(enc)); !strings.EqualFold(got, blockHash) {
		return ExecHeader{}, fmt.Errorf("header encoding hashes to %s, not %s: unknown header fields?", got, blockHash)
	}
	number, _ := hexBytes(block["number"].(string))
	timestamp, _ := hexBytes(block["timestamp"].(string))
	stateRoot, _ := hexBytes(block["stateRoot"].(string))
	return ExecHeader{
		RLP:       enc,
		Number:    new(big.Int).SetBytes(number).Uint64(),
		Timestamp: new(big.Int).SetBytes(timestamp).Uint64(),
		StateRoot: stateRoot,
	}, nil
}

// StorageProof is eth_getProof's answer for one account and one slot.
type StorageProof struct {
	AccountProof [][]byte
	StorageProof [][]byte
	Value        []byte
}

// GetProof proves storage slot key of address at block number.
func (e *Execution) GetProof(ctx context.Context, address string, key []byte, block uint64) (StorageProof, error) {
	var out struct {
		AccountProof []string `json:"accountProof"`
		StorageProof []struct {
			Value string   `json:"value"`
			Proof []string `json:"proof"`
		} `json:"storageProof"`
	}
	err := e.call(ctx, "eth_getProof", []any{address, []string{"0x" + hex.EncodeToString(key)}, fmt.Sprintf("0x%x", block)}, &out)
	if err != nil {
		return StorageProof{}, err
	}
	if len(out.StorageProof) != 1 {
		return StorageProof{}, fmt.Errorf("expected one storage proof, got %d", len(out.StorageProof))
	}
	var p StorageProof
	if p.AccountProof, err = hexList(out.AccountProof); err != nil {
		return p, err
	}
	if p.StorageProof, err = hexList(out.StorageProof[0].Proof); err != nil {
		return p, err
	}
	p.Value, err = hexBytes(out.StorageProof[0].Value)
	return p, err
}

// IBCStoreCommitmentSlot is the slot of the commitments mapping in
// solidity-ibc-eureka's IBCStoreUpgradeable (ERC-7201 namespace).
var IBCStoreCommitmentSlot = mustHex("1260944489272988d9df285149b5aa1b0f48f2136d6f416159f840a3e0747600")

func mustHex(s string) []byte {
	b, err := hex.DecodeString(s)
	if err != nil {
		panic(err)
	}
	return b
}

// CommitmentSlot is the storage slot of the router's commitments[keccak(path)]
// for a mapping at mappingSlot (32 bytes).
func CommitmentSlot(path, mappingSlot []byte) []byte {
	return keccak(append(keccak(path), mappingSlot...))
}

func keccak(b []byte) []byte {
	h := sha3.NewLegacyKeccak256()
	h.Write(b)
	return h.Sum(nil)
}

func hexBytes(s string) ([]byte, error) {
	s = strings.TrimPrefix(s, "0x")
	if len(s)%2 == 1 {
		s = "0" + s
	}
	return hex.DecodeString(s)
}

func hexList(ss []string) ([][]byte, error) {
	out := make([][]byte, len(ss))
	for i, s := range ss {
		b, err := hexBytes(s)
		if err != nil {
			return nil, err
		}
		out[i] = b
	}
	return out, nil
}

func rlpString(b []byte) []byte {
	if len(b) == 1 && b[0] < 0x80 {
		return b
	}
	return append(rlpPrefix(0x80, len(b)), b...)
}

func rlpList(items [][]byte) []byte {
	var body []byte
	for _, it := range items {
		body = append(body, it...)
	}
	return append(rlpPrefix(0xc0, len(body)), body...)
}

func rlpPrefix(base byte, n int) []byte {
	if n < 56 {
		return []byte{base + byte(n)}
	}
	l := new(big.Int).SetInt64(int64(n)).Bytes()
	return append([]byte{base + 55 + byte(len(l))}, l...)
}
