// Package ethgno turns Ethereum beacon and execution data into the messages
// of the gno-side Ethereum light client
// (gno.land/p/aib/ibc/lightclient/ethereum/v0), rendered as Gno source for
// the MsgRun scripts the relayer submits.
package ethgno

import (
	"context"
	"encoding/hex"
	"fmt"
	"strings"

	"github.com/gnolang/gno-eth-ibc/relayer/beacon"
)

// Pkg is the import name the rendered literals use for the light client
// package; the multi-line formats below spell it out.
const Pkg = "ethereum"

// ImportPath is the gno-side light client package.
const ImportPath = "gno.land/p/aib/ibc/lightclient/ethereum/v0"

// Byte values are rendered as quoted string literals converted to []byte:
// decoding hex at run time costs the interpreter about 750k gas per 48-byte
// key, which for a sync committee is most of an update's gas.

func hb(s string) string {
	b, err := hex.DecodeString(strings.TrimPrefix(s, "0x"))
	if err != nil {
		panic(fmt.Sprintf("bad hex %q: %v", s, err))
	}
	return hbytes(b)
}

func hbytes(b []byte) string { return fmt.Sprintf("[]byte(%q)", string(b)) }

func hlist(ss []string) string {
	parts := make([]string, len(ss))
	for i, s := range ss {
		parts[i] = hb(s)
	}
	return "[][]byte{" + strings.Join(parts, ", ") + "}"
}

func blist(bs [][]byte) string {
	parts := make([]string, len(bs))
	for i, b := range bs {
		parts[i] = hbytes(b)
	}
	return "[][]byte{" + strings.Join(parts, ", ") + "}"
}

// Helpers is Gno source scripts include for their own hx calls.
const Helpers = `func hx(s string) []byte {
	b, err := hex.DecodeString(s)
	if err != nil {
		panic(err)
	}
	return b
}
`

// ChainParams are the static parameters of the tracked chain, read from its
// beacon node.
type ChainParams struct {
	GenesisTime                  uint64
	GenesisValidatorsRoot        string
	GenesisForkVersion           string
	SecondsPerSlot               uint64
	SlotsPerEpoch                uint64
	EpochsPerSyncCommitteePeriod uint64
	SyncCommitteeSize            uint64
	Forks                        map[string]Fork // altair .. gloas
}

type Fork struct {
	Version string
	Epoch   uint64
}

const farFuture = ^uint64(0)

// ReadChainParams reads the chain parameters from a beacon node.
func ReadChainParams(ctx context.Context, c *beacon.Client) (ChainParams, error) {
	g, err := c.Genesis(ctx)
	if err != nil {
		return ChainParams{}, err
	}
	spec, err := c.Spec(ctx)
	if err != nil {
		return ChainParams{}, err
	}
	p := ChainParams{
		GenesisTime:           uint64(g.GenesisTime),
		GenesisValidatorsRoot: g.GenesisValidatorsRoot,
		GenesisForkVersion:    g.GenesisForkVersion,
		Forks:                 map[string]Fork{},
	}
	for key, dst := range map[string]*uint64{
		"SECONDS_PER_SLOT": &p.SecondsPerSlot, "SLOTS_PER_EPOCH": &p.SlotsPerEpoch,
		"EPOCHS_PER_SYNC_COMMITTEE_PERIOD": &p.EpochsPerSyncCommitteePeriod, "SYNC_COMMITTEE_SIZE": &p.SyncCommitteeSize,
	} {
		v, err := spec.Uint(key, 0)
		if err != nil || v == 0 {
			return ChainParams{}, fmt.Errorf("spec %s: %v", key, err)
		}
		*dst = v
	}
	for _, f := range []string{"ALTAIR", "BELLATRIX", "CAPELLA", "DENEB", "ELECTRA", "FULU", "GLOAS"} {
		epoch, err := spec.Uint(f+"_FORK_EPOCH", farFuture)
		if err != nil {
			return ChainParams{}, err
		}
		version := spec[f+"_FORK_VERSION"]
		if version == "" {
			version = "0x00000000"
		}
		p.Forks[f] = Fork{Version: version, Epoch: epoch}
	}
	return p, nil
}

func version(v string) string {
	b, err := hex.DecodeString(strings.TrimPrefix(v, "0x"))
	if err != nil || len(b) != 4 {
		panic("bad fork version " + v)
	}
	return fmt.Sprintf("[4]byte{0x%02x, 0x%02x, 0x%02x, 0x%02x}", b[0], b[1], b[2], b[3])
}

func (p ChainParams) fork(name string) string {
	f := p.Forks[name]
	epoch := fmt.Sprint(f.Epoch)
	if f.Epoch == farFuture {
		epoch = Pkg + ".FarFutureEpoch"
	}
	return fmt.Sprintf("%s.Fork{Version: %s, Epoch: %s}", Pkg, version(f.Version), epoch)
}

// ClientState renders the client state of a client of the chain p tracking
// router (20-byte address) whose commitments mapping is at commitmentSlot.
func ClientState(p ChainParams, chainID uint64, router, commitmentSlot []byte, latestSlot, latestBlock uint64) string {
	minParticipants := p.SyncCommitteeSize * 2 / 3 // updates need a supermajority anyway
	return fmt.Sprintf(`ethereum.ClientState{
	ChainID: %d,
	GenesisValidatorsRoot: %s,
	MinSyncCommitteeParticipants: %d,
	SyncCommitteeSize: %d,
	GenesisTime: %d,
	ForkParameters: ethereum.ForkParameters{
		GenesisForkVersion: %s,
		Altair: %s, Bellatrix: %s, Capella: %s, Deneb: %s, Electra: %s, Fulu: %s, Gloas: %s,
	},
	SecondsPerSlot: %d,
	SlotsPerEpoch: %d,
	EpochsPerSyncCommitteePeriod: %d,
	LatestSlot: %d,
	LatestExecutionBlockNumber: %d,
	IBCContractAddress: %s,
	IBCCommitmentSlot: %s,
}`, chainID, hb(p.GenesisValidatorsRoot), minParticipants, p.SyncCommitteeSize, p.GenesisTime,
		version(p.GenesisForkVersion), p.fork("ALTAIR"), p.fork("BELLATRIX"), p.fork("CAPELLA"), p.fork("DENEB"),
		p.fork("ELECTRA"), p.fork("FULU"), p.fork("GLOAS"),
		p.SecondsPerSlot, p.SlotsPerEpoch, p.EpochsPerSyncCommitteePeriod, latestSlot, latestBlock,
		hbytes(router), hbytes(commitmentSlot))
}

// ConsensusState renders the trusted state of a bootstrap whose execution
// block has the given state root and timestamp.
func ConsensusState(b beacon.Bootstrap, stateRoot []byte, timestamp uint64) string {
	return fmt.Sprintf(`ethereum.ConsensusState{
	Slot: %d,
	StateRoot: %s,
	Timestamp: %d,
	CurrentSyncCommittee: %s,
}`, b.Header.Beacon.Slot, hbytes(stateRoot), timestamp, summary(b.CurrentSyncCommittee))
}

func summary(c beacon.SyncCommittee) string {
	return fmt.Sprintf("%s.SummarizedSyncCommittee{PubkeysHash: %s, AggregatePubkey: %s}",
		Pkg, hbytes(PubkeysRoot(c.Pubkeys)), hb(c.AggregatePubkey))
}

func nonSigners(active beacon.SyncCommittee, bits string) string {
	var items []string
	for _, n := range NonSigners(active, bits) {
		items = append(items, fmt.Sprintf("{Pubkey: %s, Branch: %s}", hbytes(n.Pubkey), blist(n.Branch)))
	}
	return "[]" + Pkg + ".NonSigner{" + strings.Join(items, ", ") + "}"
}

func lcHeader(h beacon.LightClientHeader) string {
	b := h.Beacon
	beaconLit := fmt.Sprintf("%s.BeaconBlockHeader{Slot: %d, ProposerIndex: %d, ParentRoot: %s, StateRoot: %s, BodyRoot: %s}",
		Pkg, b.Slot, b.ProposerIndex, hb(b.ParentRoot), hb(b.StateRoot), hb(b.BodyRoot))
	if h.Execution == nil {
		return fmt.Sprintf("%s.LightClientHeader{Beacon: %s, ExecutionBlockHash: %s, ExecutionBranch: %s}",
			Pkg, beaconLit, hb(h.ExecutionBlockHash), hlist(h.ExecutionBranch))
	}
	e := h.Execution
	baseFee, ok := decimalBytes(e.BaseFeePerGas)
	if !ok {
		panic("bad base fee " + e.BaseFeePerGas)
	}
	return fmt.Sprintf(`ethereum.LightClientHeader{
	Beacon: %s,
	Execution: ethereum.ExecutionPayloadHeader{ParentHash: %s, FeeRecipient: %s, StateRoot: %s, ReceiptsRoot: %s, LogsBloom: %s, PrevRandao: %s, BlockNumber: %d, GasLimit: %d, GasUsed: %d, Timestamp: %d, ExtraData: %s, BaseFeePerGas: %s, BlockHash: %s, TransactionsRoot: %s, WithdrawalsRoot: %s, BlobGasUsed: %d, ExcessBlobGas: %d},
	ExecutionBranch: %s,
}`, beaconLit, hb(e.ParentHash), hb(e.FeeRecipient), hb(e.StateRoot), hb(e.ReceiptsRoot), hb(e.LogsBloom),
		hb(e.PrevRandao), e.BlockNumber, e.GasLimit, e.GasUsed, e.Timestamp, hb(e.ExtraData), hbytes(baseFee),
		hb(e.BlockHash), hb(e.TransactionsRoot), hb(e.WithdrawalsRoot), e.BlobGasUsed, e.ExcessBlobGas,
		hlist(h.ExecutionBranch))
}

// Header renders a client update: u applied on top of the consensus state at
// trustedSlot, whose active sync committee (current, or next if isNext) is
// active. finalizedExecHeader is the RLP execution header of u's finalized
// header, required from Gloas on (nil before).
func Header(u beacon.LightClientUpdate, active beacon.SyncCommittee, isNext bool, trustedSlot uint64, finalizedExecHeader []byte) string {
	next, nextBranch := "nil", "nil"
	if u.NextSyncCommittee != nil {
		next = "&" + summary(*u.NextSyncCommittee)
		nextBranch = hlist(u.NextSyncCommitteeBranch)
	}
	execHeader := "nil"
	if finalizedExecHeader != nil {
		execHeader = hbytes(finalizedExecHeader)
	}
	return fmt.Sprintf(`&ethereum.Header{
	ActiveIsNext: %t,
	TrustedSlot: %d,
	ConsensusUpdate: ethereum.LightClientUpdate{
		AttestedHeader: %s,
		NextSyncCommittee: %s,
		NextSyncCommitteeBranch: %s,
		FinalizedHeader: %s,
		FinalityBranch: %s,
		SyncAggregate: ethereum.SyncAggregate{SyncCommitteeBits: %s, SyncCommitteeSignature: %s},
		SignatureSlot: %d,
		FinalizedExecutionHeader: %s,
		NonSigners: %s,
	},
}`, isNext, trustedSlot, lcHeader(u.AttestedHeader), next, nextBranch,
		lcHeader(u.FinalizedHeader), hlist(u.FinalityBranch), hb(u.SyncAggregate.SyncCommitteeBits),
		hb(u.SyncAggregate.SyncCommitteeSignature), u.SignatureSlot, execHeader,
		nonSigners(active, u.SyncAggregate.SyncCommitteeBits))
}

// MembershipProof renders a storage proof for the client's extproof.Proof.
func MembershipProof(p StorageProof) string {
	return fmt.Sprintf("%s.MembershipProof{AccountProof: %s, StorageProof: %s}", Pkg, blist(p.AccountProof), blist(p.StorageProof))
}

// decimalBytes returns the minimal big-endian bytes of a decimal string.
func decimalBytes(s string) ([]byte, bool) {
	n, ok := new(bigInt).SetString(s, 10)
	if !ok {
		return nil, false
	}
	return n.Bytes(), true
}
