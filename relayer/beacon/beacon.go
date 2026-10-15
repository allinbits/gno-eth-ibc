// Package beacon is a client of the Ethereum beacon node API endpoints a
// light-client relayer needs: genesis, spec, and the light-client data
// (bootstrap, updates, finality update).
package beacon

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
)

// Client talks to one beacon node.
type Client struct {
	BaseURL string
	HTTP    *http.Client
}

func New(baseURL string) *Client {
	return &Client{BaseURL: strings.TrimRight(baseURL, "/"), HTTP: http.DefaultClient}
}

func (c *Client) get(ctx context.Context, path string, out any) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.BaseURL+path, nil)
	if err != nil {
		return err
	}
	req.Header.Set("Accept", "application/json")
	res, err := c.HTTP.Do(req)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	body, err := io.ReadAll(res.Body)
	if err != nil {
		return err
	}
	if res.StatusCode != http.StatusOK {
		return fmt.Errorf("beacon %s: %s: %s", path, res.Status, truncate(body))
	}
	if err := json.Unmarshal(body, out); err != nil {
		return fmt.Errorf("beacon %s: %w", path, err)
	}
	return nil
}

func truncate(b []byte) string {
	if len(b) > 300 {
		b = b[:300]
	}
	return string(b)
}

// Uint64 is a uint64 the beacon API encodes as a decimal string.
type Uint64 uint64

// MarshalJSON writes the decimal string the beacon API uses.
func (u Uint64) MarshalJSON() ([]byte, error) {
	return []byte(`"` + strconv.FormatUint(uint64(u), 10) + `"`), nil
}

func (u *Uint64) UnmarshalJSON(b []byte) error {
	s := strings.Trim(string(b), `"`)
	v, err := strconv.ParseUint(s, 10, 64)
	if err != nil {
		return err
	}
	*u = Uint64(v)
	return nil
}

// Genesis is /eth/v1/beacon/genesis.
type Genesis struct {
	GenesisTime           Uint64 `json:"genesis_time"`
	GenesisValidatorsRoot string `json:"genesis_validators_root"`
	GenesisForkVersion    string `json:"genesis_fork_version"`
}

func (c *Client) Genesis(ctx context.Context) (Genesis, error) {
	var out struct{ Data Genesis }
	return out.Data, c.get(ctx, "/eth/v1/beacon/genesis", &out)
}

// Spec is /eth/v1/config/spec: string-valued chain parameters.
type Spec map[string]string

func (c *Client) Spec(ctx context.Context) (Spec, error) {
	// Some values (blob schedules) are arrays; keep the scalar ones.
	var out struct{ Data map[string]json.RawMessage }
	if err := c.get(ctx, "/eth/v1/config/spec", &out); err != nil {
		return nil, err
	}
	spec := Spec{}
	for k, raw := range out.Data {
		var s string
		if json.Unmarshal(raw, &s) == nil {
			spec[k] = s
		}
	}
	return spec, nil
}

// Uint returns the spec value key, or def when the node does not report it
// (an unscheduled fork's epoch, for instance).
func (s Spec) Uint(key string, def uint64) (uint64, error) {
	v, ok := s[key]
	if !ok {
		return def, nil
	}
	return strconv.ParseUint(v, 10, 64)
}

type BeaconBlockHeader struct {
	Slot          Uint64 `json:"slot"`
	ProposerIndex Uint64 `json:"proposer_index"`
	ParentRoot    string `json:"parent_root"`
	StateRoot     string `json:"state_root"`
	BodyRoot      string `json:"body_root"`
}

// ExecutionPayloadHeader is the pre-Gloas execution part of a light-client
// header. Numbers are decimal strings in the beacon API.
type ExecutionPayloadHeader struct {
	ParentHash       string `json:"parent_hash"`
	FeeRecipient     string `json:"fee_recipient"`
	StateRoot        string `json:"state_root"`
	ReceiptsRoot     string `json:"receipts_root"`
	LogsBloom        string `json:"logs_bloom"`
	PrevRandao       string `json:"prev_randao"`
	BlockNumber      Uint64 `json:"block_number"`
	GasLimit         Uint64 `json:"gas_limit"`
	GasUsed          Uint64 `json:"gas_used"`
	Timestamp        Uint64 `json:"timestamp"`
	ExtraData        string `json:"extra_data"`
	BaseFeePerGas    string `json:"base_fee_per_gas"`
	BlockHash        string `json:"block_hash"`
	TransactionsRoot string `json:"transactions_root"`
	WithdrawalsRoot  string `json:"withdrawals_root"`
	BlobGasUsed      Uint64 `json:"blob_gas_used"`
	ExcessBlobGas    Uint64 `json:"excess_blob_gas"`
}

// LightClientHeader covers both layouts: Execution before Gloas,
// ExecutionBlockHash from Gloas on.
type LightClientHeader struct {
	Beacon             BeaconBlockHeader       `json:"beacon"`
	Execution          *ExecutionPayloadHeader `json:"execution,omitempty"`
	ExecutionBlockHash string                  `json:"execution_block_hash,omitempty"`
	ExecutionBranch    []string                `json:"execution_branch"`
}

// BlockHash is the execution block hash the header commits to.
func (h LightClientHeader) BlockHash() string {
	if h.Execution != nil {
		return h.Execution.BlockHash
	}
	return h.ExecutionBlockHash
}

type SyncCommittee struct {
	Pubkeys         []string `json:"pubkeys"`
	AggregatePubkey string   `json:"aggregate_pubkey"`
}

type SyncAggregate struct {
	SyncCommitteeBits      string `json:"sync_committee_bits"`
	SyncCommitteeSignature string `json:"sync_committee_signature"`
}

// LightClientUpdate is an update or a finality update (which has no next
// sync committee).
type LightClientUpdate struct {
	AttestedHeader          LightClientHeader `json:"attested_header"`
	NextSyncCommittee       *SyncCommittee    `json:"next_sync_committee,omitempty"`
	NextSyncCommitteeBranch []string          `json:"next_sync_committee_branch,omitempty"`
	FinalizedHeader         LightClientHeader `json:"finalized_header"`
	FinalityBranch          []string          `json:"finality_branch"`
	SyncAggregate           SyncAggregate     `json:"sync_aggregate"`
	SignatureSlot           Uint64            `json:"signature_slot"`
}

type Bootstrap struct {
	Header                     LightClientHeader `json:"header"`
	CurrentSyncCommittee       SyncCommittee     `json:"current_sync_committee"`
	CurrentSyncCommitteeBranch []string          `json:"current_sync_committee_branch"`
}

func (c *Client) Bootstrap(ctx context.Context, blockRoot string) (Bootstrap, error) {
	var out struct{ Data Bootstrap }
	return out.Data, c.get(ctx, "/eth/v1/beacon/light_client/bootstrap/"+blockRoot, &out)
}

// Updates returns the best update of each period from start.
func (c *Client) Updates(ctx context.Context, start, count uint64) ([]LightClientUpdate, error) {
	var out []struct{ Data LightClientUpdate }
	if err := c.get(ctx, fmt.Sprintf("/eth/v1/beacon/light_client/updates?start_period=%d&count=%d", start, count), &out); err != nil {
		return nil, err
	}
	us := make([]LightClientUpdate, len(out))
	for i, o := range out {
		us[i] = o.Data
	}
	return us, nil
}

func (c *Client) FinalityUpdate(ctx context.Context) (LightClientUpdate, error) {
	var out struct{ Data LightClientUpdate }
	return out.Data, c.get(ctx, "/eth/v1/beacon/light_client/finality_update", &out)
}

// BlockRoot returns the root of the block at block id (a slot, "finalized",
// "head" or a root).
func (c *Client) BlockRoot(ctx context.Context, id string) (string, error) {
	var out struct{ Data struct{ Root string } }
	return out.Data.Root, c.get(ctx, "/eth/v1/beacon/blocks/"+id+"/root", &out)
}
