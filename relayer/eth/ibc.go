package eth

import (
	"context"
	"fmt"
	"github.com/ethereum/go-ethereum"
	"math/big"

	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/accounts/abi/bind"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"

	"github.com/gnolang/gno-eth-ibc/relayer/gnoibc"
	"github.com/gnolang/gno-eth-ibc/relayer/ibc"
)

// The ABI shapes of IICS26RouterMsgs; go-ethereum matches fields by name.
type abiPayload struct {
	SourcePort string
	DestPort   string
	Version    string
	Encoding   string
	Value      []byte
}

type abiPacket struct {
	Sequence         uint64
	SourceClient     string
	DestClient       string
	TimeoutTimestamp uint64
	Payloads         []abiPayload
}

type abiHeight struct {
	RevisionNumber uint64
	RevisionHeight uint64
}

type abiMsgRecvPacket struct {
	Packet          abiPacket
	ProofCommitment []byte
	ProofHeight     abiHeight
}

func toABIPacket(p ibc.Packet) abiPacket {
	out := abiPacket{
		Sequence: p.Sequence, SourceClient: p.SourceClient, DestClient: p.DestinationClient,
		TimeoutTimestamp: p.TimeoutTimestamp,
	}
	for _, pl := range p.Payloads {
		out.Payloads = append(out.Payloads, abiPayload{pl.SourcePort, pl.DestinationPort, pl.Version, pl.Encoding, pl.Value})
	}
	return out
}

// LightClientState returns GnoLightClient's client state.
func (c *Client) LightClientState(ctx context.Context) (gnoibc.ClientState, error) {
	bz, err := call[[]byte](ctx, c.LightClient, "getClientState")
	if err != nil {
		return gnoibc.ClientState{}, err
	}
	return gnoibc.UnpackClientState(bz)
}

// ConsensusState returns GnoLightClient's consensus state at a gno height.
func (c *Client) ConsensusState(ctx context.Context, height uint64) (gnoibc.ConsensusState, error) {
	var out []any
	if err := c.LightClient.Call(&bind.CallOpts{Context: ctx}, &out, "getConsensusState", height); err != nil {
		return gnoibc.ConsensusState{}, err
	}
	v := *abi.ConvertType(out[0], new(gnoibc.ConsensusState)).(*gnoibc.ConsensusState)
	return v, nil
}

// IsValidatorSetCached reports whether GnoLightClient holds the validator set
// with this tm2 hash, so that updates may leave it out.
func (c *Client) IsValidatorSetCached(ctx context.Context, valSetHash [32]byte) (bool, error) {
	return call[bool](ctx, c.LightClient, "isValidatorSetCached", valSetHash)
}

// UpdateClient submits a GnoLightClient update through the router.
func (c *Client) UpdateClient(ctx context.Context, msg []byte) (*types.Receipt, error) {
	return c.transact(ctx, c.Router, "updateClient", c.Dep.ClientID, msg)
}

// RecvPacket submits ICS26Router.recvPacket.
func (c *Client) RecvPacket(ctx context.Context, p ibc.Packet, proof []byte, proofHeight ibc.Height) (*types.Receipt, error) {
	msg := abiMsgRecvPacket{
		Packet:          toABIPacket(p),
		ProofCommitment: proof,
		ProofHeight:     abiHeight{proofHeight.RevisionNumber, proofHeight.RevisionHeight},
	}
	return c.transact(ctx, c.Router, "recvPacket", msg)
}

// Commitment reads ICS26Router's commitment store at keccak256(path).
func (c *Client) Commitment(ctx context.Context, path []byte) ([32]byte, error) {
	return c.CommitmentAt(ctx, path, nil)
}

// CommitmentAt reads the commitment at path as of block (nil = latest).
func (c *Client) CommitmentAt(ctx context.Context, path []byte, block *big.Int) ([32]byte, error) {
	return callAt[[32]byte](ctx, block, c.Router, "getCommitment", crypto.Keccak256Hash(path))
}

// WrittenAck finds the acknowledgement the router wrote for a packet it
// received on clientID, and the block it was written in. The router's logs
// are scanned newest first, back to the deployment block at most.
func (c *Client) WrittenAck(ctx context.Context, clientID string, sequence uint64) ([][]byte, uint64, error) {
	ev := RouterABI.Events["WriteAcknowledgement"]
	head, err := c.Logs.BlockNumber(ctx)
	if err != nil {
		return nil, 0, err
	}
	seq := common.BigToHash(new(big.Int).SetUint64(sequence))
	l, ok, err := c.lastLog(ctx, ethereum.FilterQuery{
		Addresses: []common.Address{c.Dep.ICS26Router},
		Topics:    [][]common.Hash{{ev.ID}, {crypto.Keccak256Hash([]byte(clientID))}, {seq}},
	}, c.Dep.DeployBlock, head)
	if err != nil {
		return nil, 0, err
	}
	if !ok {
		return nil, 0, fmt.Errorf("no acknowledgement written for %s/%d", clientID, sequence)
	}
	vals, err := ev.Inputs.NonIndexed().Unpack(l.Data)
	if err != nil {
		return nil, 0, fmt.Errorf("WriteAcknowledgement: %w", err)
	}
	for i, in := range ev.Inputs.NonIndexed() {
		if in.Name == "acknowledgements" {
			return vals[i].([][]byte), l.BlockNumber, nil
		}
	}
	return nil, 0, fmt.Errorf("WriteAcknowledgement has no acknowledgements")
}

// WrittenAcks extracts the acknowledgements of WriteAcknowledgement events in
// a receipt, by packet sequence.
func (c *Client) WrittenAcks(rcpt *types.Receipt) (map[uint64][][]byte, error) {
	ev := RouterABI.Events["WriteAcknowledgement"]
	out := map[uint64][][]byte{}
	for _, l := range rcpt.Logs {
		if l.Address != c.Dep.ICS26Router || len(l.Topics) == 0 || l.Topics[0] != ev.ID {
			continue
		}
		vals, err := ev.Inputs.NonIndexed().Unpack(l.Data)
		if err != nil {
			return nil, fmt.Errorf("WriteAcknowledgement: %w", err)
		}
		var seq uint64
		var acks [][]byte
		for i, in := range ev.Inputs.NonIndexed() {
			switch in.Name {
			case "packet":
				seq = abi.ConvertType(vals[i], new(abiPacket)).(*abiPacket).Sequence
			case "acknowledgements":
				acks = vals[i].([][]byte)
			}
		}
		out[seq] = acks
	}
	return out, nil
}

// IBCERC20 returns the voucher contract ICS20Transfer minted for a full denom
// path (e.g. "transfer/client-0/ugnot"), or the zero address.
func (c *Client) IBCERC20(ctx context.Context, denom string) (common.Address, error) {
	return call[common.Address](ctx, c.Transfer, "ibcERC20Contract", denom)
}

// BalanceOf reads an ERC20 balance.
func (c *Client) BalanceOf(ctx context.Context, token, owner common.Address) (*big.Int, error) {
	return call[*big.Int](ctx, bindERC20(c, token), "balanceOf", owner)
}

type abiMsgAckPacket struct {
	Packet          abiPacket
	Acknowledgement []byte
	ProofAcked      []byte
	ProofHeight     abiHeight
}

// AckPacket delivers the acknowledgement gno wrote for a packet sent from the
// EVM chain.
func (c *Client) AckPacket(ctx context.Context, p ibc.Packet, ack, proof []byte, proofHeight ibc.Height) (*types.Receipt, error) {
	return c.transact(ctx, c.Router, "ackPacket", abiMsgAckPacket{
		Packet:          toABIPacket(p),
		Acknowledgement: ack,
		ProofAcked:      proof,
		ProofHeight:     abiHeight{proofHeight.RevisionNumber, proofHeight.RevisionHeight},
	})
}
