package relay

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log/slog"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/gnolang/gno-eth-ibc/relayer/beacon"
	"github.com/gnolang/gno-eth-ibc/relayer/eth"
	"github.com/gnolang/gno-eth-ibc/relayer/ethgno"
	"github.com/gnolang/gno-eth-ibc/relayer/gno"
	"github.com/gnolang/gno-eth-ibc/relayer/ibc"
)

// EthRelayRealm takes wire-encoded Ethereum client messages and packets as
// MsgCall arguments.
const EthRelayRealm = "gno.land/r/aib/ibc/ethrelay"

// EthToGno relays Ethereum to gno.land through EthRelayRealm: it keeps gno's
// Ethereum light client (GnoClientID) following the beacon chain, delivers
// packets the router sent to it, and relays the acknowledgements the router
// wrote for packets from gno (it is an AckRelayer).
type EthToGno struct {
	Gno    *gno.Client
	Eth    *eth.Client
	Beacon *beacon.Client
	// Exec serves eth_getProof at the finalized block: it needs more state
	// history than most public RPCs keep (they stop about 64 blocks behind
	// head, while finality lags 64 to 96).
	Exec        *ethgno.Execution
	GnoClientID string
	Tx          gno.TxConfig
	Log         *slog.Logger

	params ethgno.ChainParams
	// execBlock maps the slots of consensus states this relayer created to
	// their execution block numbers.
	execBlock map[uint64]uint64
}

// Init reads the tracked chain's parameters.
func (r *EthToGno) Init(ctx context.Context) error {
	p, err := ethgno.ReadChainParams(ctx, r.Beacon)
	if err != nil {
		return err
	}
	r.params = p
	r.execBlock = map[uint64]uint64{}
	if r.Log == nil {
		r.Log = slog.Default()
	}
	return nil
}

func (r *EthToGno) slotsPerPeriod() uint64 {
	return r.params.SlotsPerEpoch * r.params.EpochsPerSyncCommitteePeriod
}

func (r *EthToGno) slotTime(slot uint64) time.Time {
	return time.Unix(int64(r.params.GenesisTime+slot*r.params.SecondsPerSlot), 0)
}

var qevalString = regexp.MustCompile(`(?s)^\("(.*)" string\)`)

// render returns the core realm's Render(path) output.
func (r *EthToGno) render(ctx context.Context, path string) (string, error) {
	out, err := r.Gno.QEval(ctx, gno.CoreRealm, fmt.Sprintf("Render(%q)", path))
	if err != nil {
		return "", err
	}
	m := qevalString.FindStringSubmatch(out)
	if m == nil {
		return "", fmt.Errorf("unexpected qeval output %q", out)
	}
	return strconv.Unquote(`"` + m[1] + `"`)
}

type ethConsensusState struct {
	Slot                   uint64 `json:"slot"`
	NextSyncCommitteeKnown bool   `json:"next_sync_committee_known"`
}

// trusted returns gno's client latest consensus state.
func (r *EthToGno) trusted(ctx context.Context) (ethConsensusState, error) {
	out, err := r.Gno.QEval(ctx, gno.CoreRealm, fmt.Sprintf("ClientLatestHeight(%q)", r.GnoClientID))
	if err != nil {
		return ethConsensusState{}, err
	}
	m := qevalString.FindStringSubmatch(out)
	if m == nil {
		return ethConsensusState{}, fmt.Errorf("unexpected latest height %q", out)
	}
	js, err := r.render(ctx, fmt.Sprintf("clients/%s/consensus_states/%s", r.GnoClientID, m[1]))
	if err != nil {
		return ethConsensusState{}, err
	}
	var cs ethConsensusState
	if err := json.Unmarshal([]byte(js), &cs); err != nil {
		return cs, fmt.Errorf("consensus state %q: %w", js, err)
	}
	return cs, nil
}

// committee returns the sync committee of period p: the next committee the
// best update of period p-1 revealed.
func (r *EthToGno) committee(ctx context.Context, p uint64) (beacon.SyncCommittee, error) {
	us, err := r.Beacon.Updates(ctx, p-1, 1)
	if err != nil {
		return beacon.SyncCommittee{}, err
	}
	if len(us) != 1 || us[0].NextSyncCommittee == nil {
		return beacon.SyncCommittee{}, fmt.Errorf("no sync committee for period %d", p)
	}
	return *us[0].NextSyncCommittee, nil
}

// waitGnoTime waits until gno's block time reaches t: the client rejects
// updates signed after its current slot.
func (r *EthToGno) waitGnoTime(ctx context.Context, t time.Time) error {
	for {
		h, err := r.Gno.LatestHeight(ctx)
		if err != nil {
			return err
		}
		sh, err := r.Gno.SignedHeader(ctx, h)
		if err != nil {
			return err
		}
		if !sh.Time.Before(t) {
			return nil
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(2 * time.Second):
		}
	}
}

// apply submits update u on top of the consensus state at trustedSlot.
func (r *EthToGno) apply(ctx context.Context, u beacon.LightClientUpdate, active beacon.SyncCommittee, isNext bool, trustedSlot uint64) error {
	var rlp []byte
	exec, err := r.Exec.Header(ctx, u.FinalizedHeader.BlockHash())
	if err != nil {
		return fmt.Errorf("finalized execution header: %w", err)
	}
	if u.FinalizedHeader.Execution == nil {
		rlp = exec.RLP // Gloas: the client reads the state root from it
	}
	if err := r.waitGnoTime(ctx, r.slotTime(uint64(u.SignatureSlot))); err != nil {
		return err
	}
	msg := ethgno.EncodeHeader(u, active, isNext, trustedSlot, rlp)
	res, err := r.Gno.Call(r.Tx, EthRelayRealm, "UpdateClient", nil, r.GnoClientID, base64.StdEncoding.EncodeToString(msg))
	if err != nil {
		return fmt.Errorf("update client: %w", err)
	}
	finalized := uint64(u.FinalizedHeader.Beacon.Slot)
	if finalized > trustedSlot {
		r.execBlock[finalized] = exec.Number
	}
	r.Log.Info("updated gno's Ethereum client", "client", r.GnoClientID, "trusted", trustedSlot,
		"finalized", finalized, "execBlock", exec.Number, "bytes", len(msg), "gas", res.DeliverTx.GasUsed)
	return nil
}

// UpdateTo brings gno's client to a finalized state whose execution block is
// at least minBlock, and returns that state's slot and execution block.
func (r *EthToGno) UpdateTo(ctx context.Context, minBlock uint64) (slot, block uint64, err error) {
	spp := r.slotsPerPeriod()
	for {
		cs, err := r.trusted(ctx)
		if err != nil {
			return 0, 0, err
		}
		if b, ok := r.execBlock[cs.Slot]; ok && b >= minBlock {
			return cs.Slot, b, nil
		}
		period := cs.Slot / spp
		if !cs.NextSyncCommitteeKnown {
			// Learn the next committee first: without it the client cannot
			// follow finality into the next period.
			active, err := r.committee(ctx, period)
			if err != nil {
				return 0, 0, err
			}
			us, err := r.Beacon.Updates(ctx, period, 1)
			if err != nil || len(us) != 1 {
				return 0, 0, fmt.Errorf("period %d update: %v", period, err)
			}
			if err := r.apply(ctx, us[0], active, false, cs.Slot); err != nil {
				return 0, 0, err
			}
			continue
		}
		fin, err := r.Beacon.FinalityUpdate(ctx)
		if err != nil {
			return 0, 0, err
		}
		if uint64(fin.FinalizedHeader.Beacon.Slot) <= cs.Slot {
			r.Log.Info("waiting for Ethereum finality", "trusted", cs.Slot, "finalized", fin.FinalizedHeader.Beacon.Slot)
			select {
			case <-ctx.Done():
				return 0, 0, ctx.Err()
			case <-time.After(time.Duration(r.params.SecondsPerSlot) * time.Second):
			}
			continue
		}
		sigPeriod := uint64(fin.SignatureSlot) / spp
		switch {
		case sigPeriod == period:
			active, err := r.committee(ctx, period)
			if err != nil {
				return 0, 0, err
			}
			err = r.apply(ctx, fin, active, false, cs.Slot)
			if err != nil {
				return 0, 0, err
			}
		case sigPeriod == period+1:
			active, err := r.committee(ctx, period+1)
			if err != nil {
				return 0, 0, err
			}
			if err := r.apply(ctx, fin, active, true, cs.Slot); err != nil {
				return 0, 0, err
			}
		default:
			// Several periods behind: step into the next one with its best
			// update, signed by the next committee.
			active, err := r.committee(ctx, period+1)
			if err != nil {
				return 0, 0, err
			}
			us, err := r.Beacon.Updates(ctx, period+1, 1)
			if err != nil || len(us) != 1 {
				return 0, 0, fmt.Errorf("period %d update: %v", period+1, err)
			}
			if err := r.apply(ctx, us[0], active, true, cs.Slot); err != nil {
				return 0, 0, err
			}
		}
	}
}

// proof proves the router's commitment at an ICS24 path at execution block.
func (r *EthToGno) proof(ctx context.Context, path []byte, block uint64) (ethgno.StorageProof, error) {
	return r.Exec.GetProof(ctx, r.Eth.Dep.ICS26Router.Hex(),
		ethgno.CommitmentSlot(path, ethgno.IBCStoreCommitmentSlot), block)
}

func toEthgnoPacket(p ibc.Packet) ethgno.Packet {
	out := ethgno.Packet{Sequence: p.Sequence, SourceClient: p.SourceClient,
		DestinationClient: p.DestinationClient, TimeoutTimestamp: p.TimeoutTimestamp}
	for _, pl := range p.Payloads {
		out.Payloads = append(out.Payloads, ethgno.Payload{SourcePort: pl.SourcePort,
			DestinationPort: pl.DestinationPort, Version: pl.Version, Encoding: pl.Encoding, Value: pl.Value})
	}
	return out
}

// EthRelayed is the outcome for one packet sent on Ethereum.
type EthRelayed struct {
	Packet    ibc.Packet
	ProofSlot uint64
	RecvGas   int64
	Result    string
}

// RelayRange delivers to gno the packets the router sent to GnoClientID in
// Ethereum blocks [from, to].
func (r *EthToGno) RelayRange(ctx context.Context, from, to uint64) ([]EthRelayed, error) {
	sent, err := r.Eth.SendPackets(ctx, from, to)
	if err != nil {
		return nil, err
	}
	var out []EthRelayed
	for _, s := range sent {
		if s.Packet.DestinationClient != r.GnoClientID {
			continue
		}
		slot, block, err := r.UpdateTo(ctx, s.Block)
		if err != nil {
			return out, err
		}
		path := ibc.Path(s.Packet.SourceClient, ibc.KindPacketCommitment, s.Packet.Sequence)
		p, err := r.proof(ctx, path, block)
		if err != nil {
			return out, fmt.Errorf("packet %d proof: %w", s.Packet.Sequence, err)
		}
		msg := ethgno.EncodePacketMsg(toEthgnoPacket(s.Packet), slot, nil, p)
		res, err := r.Gno.Call(r.Tx, EthRelayRealm, "RecvPacket", nil, base64.StdEncoding.EncodeToString(msg))
		if err != nil {
			return out, fmt.Errorf("core.RecvPacket %d: %w", s.Packet.Sequence, err)
		}
		rel := EthRelayed{Packet: s.Packet, ProofSlot: slot, RecvGas: res.DeliverTx.GasUsed,
			Result: strings.TrimSpace(string(res.DeliverTx.Data))}
		r.Log.Info("received packet on gno", "client", r.GnoClientID, "sequence", s.Packet.Sequence,
			"proofSlot", slot, "gas", rel.RecvGas, "result", rel.Result)
		out = append(out, rel)
	}
	return out, nil
}

// RelayAck implements AckRelayer: it proves the acknowledgement the router
// wrote and delivers it with ethrelay.Acknowledgement.
func (r *EthToGno) RelayAck(ctx context.Context, w WrittenAck) error {
	slot, block, err := r.UpdateTo(ctx, w.EVMBlock)
	if err != nil {
		return err
	}
	path := ibc.Path(w.Packet.DestinationClient, ibc.KindAcknowledgement, w.Packet.Sequence)
	p, err := r.proof(ctx, path, block)
	if err != nil {
		return fmt.Errorf("ack proof: %w", err)
	}
	msg := ethgno.EncodePacketMsg(toEthgnoPacket(w.Packet), slot, w.Acks, p)
	res, err := r.Gno.Call(r.Tx, EthRelayRealm, "Acknowledgement", nil, base64.StdEncoding.EncodeToString(msg))
	if err != nil {
		return fmt.Errorf("ethrelay.Acknowledgement %d: %w", w.Packet.Sequence, err)
	}
	r.Log.Info("acknowledged packet on gno", "client", w.Packet.SourceClient, "sequence", w.Packet.Sequence,
		"proofSlot", slot, "gas", res.DeliverTx.GasUsed)
	return nil
}
