package eth

import (
	"context"
	"fmt"
	"math/big"

	"github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/ethclient"
)

// LogSource serves the log scans: ethclient.Client, or a fake in tests.
type LogSource interface {
	BlockNumber(ctx context.Context) (uint64, error)
	FilterLogs(ctx context.Context, q ethereum.FilterQuery) ([]types.Log, error)
}

var _ LogSource = (*ethclient.Client)(nil)

// DefaultLogChunk is the block range of one eth_getLogs until the RPC refuses
// one. Public RPCs cap the range of a request (Sepolia's ethpandaops:
// "getLogs request exceeded max allowed range") or its result size; a refused
// chunk is halved, and the client keeps the size that worked.
const DefaultLogChunk = 10_000

// scanLogs runs q over blocks [from, to] in chunks, oldest or newest first,
// handing each chunk's logs to visit until it returns false. A chunk the RPC
// refuses is halved and retried, down to one block, whose failure is
// returned.
func (c *Client) scanLogs(ctx context.Context, q ethereum.FilterQuery, from, to uint64, newestFirst bool, visit func([]types.Log) (more bool)) error {
	if c.logChunk == 0 {
		c.logChunk = DefaultLogChunk
	}
	for from <= to {
		lo, hi := from, to
		if hi-lo+1 > c.logChunk {
			if newestFirst {
				lo = hi - c.logChunk + 1
			} else {
				hi = lo + c.logChunk - 1
			}
		}
		q.FromBlock, q.ToBlock = new(big.Int).SetUint64(lo), new(big.Int).SetUint64(hi)
		logs, err := c.Logs.FilterLogs(ctx, q)
		if err != nil {
			if width := hi - lo + 1; width > 1 && ctx.Err() == nil {
				c.logChunk = width / 2
				continue
			}
			return fmt.Errorf("logs of blocks %d-%d: %w", lo, hi, err)
		}
		if !visit(logs) {
			return nil
		}
		if newestFirst {
			if lo == from {
				return nil
			}
			to = lo - 1
		} else {
			if hi == to {
				return nil
			}
			from = hi + 1
		}
	}
	return nil
}

// allLogs returns every log of q in [from, to], oldest first.
func (c *Client) allLogs(ctx context.Context, q ethereum.FilterQuery, from, to uint64) ([]types.Log, error) {
	var out []types.Log
	err := c.scanLogs(ctx, q, from, to, false, func(logs []types.Log) bool {
		out = append(out, logs...)
		return true
	})
	return out, err
}

// lastLog returns the newest log of q in [from, to], scanning newest first
// and stopping at the first chunk holding one; ok is false when there is
// none.
func (c *Client) lastLog(ctx context.Context, q ethereum.FilterQuery, from, to uint64) (last types.Log, ok bool, err error) {
	err = c.scanLogs(ctx, q, from, to, true, func(logs []types.Log) bool {
		if len(logs) == 0 {
			return true
		}
		last, ok = logs[len(logs)-1], true
		return false
	})
	return last, ok, err
}
