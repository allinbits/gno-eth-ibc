package eth

import (
	"context"
	"fmt"
	"math/big"

	"github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"

	"github.com/gnolang/gno-eth-ibc/relayer/ibc"
)

// SentPacket is a packet ICS26Router emitted in SendPacket.
type SentPacket struct {
	Packet ibc.Packet
	Block  uint64
}

// SendPackets returns the packets the router sent in blocks [from, to].
func (c *Client) SendPackets(ctx context.Context, from, to uint64) ([]SentPacket, error) {
	ev := RouterABI.Events["SendPacket"]
	logs, err := c.EC.FilterLogs(ctx, ethereum.FilterQuery{
		FromBlock: new(big.Int).SetUint64(from),
		ToBlock:   new(big.Int).SetUint64(to),
		Addresses: []common.Address{c.Dep.ICS26Router},
		Topics:    [][]common.Hash{{ev.ID}},
	})
	if err != nil {
		return nil, err
	}
	var out []SentPacket
	for _, l := range logs {
		vals, err := ev.Inputs.NonIndexed().Unpack(l.Data)
		if err != nil {
			return nil, fmt.Errorf("SendPacket: %w", err)
		}
		p := abi.ConvertType(vals[0], new(abiPacket)).(*abiPacket)
		out = append(out, SentPacket{Packet: fromABIPacket(*p), Block: l.BlockNumber})
	}
	return out, nil
}

func fromABIPacket(p abiPacket) ibc.Packet {
	out := ibc.Packet{
		Sequence: p.Sequence, SourceClient: p.SourceClient, DestinationClient: p.DestClient,
		TimeoutTimestamp: p.TimeoutTimestamp,
	}
	for _, pl := range p.Payloads {
		out.Payloads = append(out.Payloads, ibc.Payload{
			SourcePort: pl.SourcePort, DestinationPort: pl.DestPort, Version: pl.Version,
			Encoding: pl.Encoding, Value: pl.Value,
		})
	}
	return out
}
