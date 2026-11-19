package gno

import (
	"errors"
	"testing"

	ctypes "github.com/gnolang/gno/tm2/pkg/bft/rpc/core/types"
)

// A transaction refused for a stale account sequence (another relayer
// signing with the same key got there first) is submitted again; any other
// failure is returned at once, and the retries are bounded.
func TestRetrySequence(t *testing.T) {
	stale := errors.New("check transaction failed: log:--= Error =--\nData: std.UnauthorizedError{abciError:std.abciError{}}\nMsg Traces:\n    0  ante.go:285 - signature verification failed; verify correct account, sequence, and chain-id")
	ok := &ctypes.ResultBroadcastTxCommit{Height: 9}

	calls := 0
	res, err := retrySequence(5, 0, func() (*ctypes.ResultBroadcastTxCommit, error) {
		calls++
		if calls < 3 {
			return nil, stale
		}
		return ok, nil
	})
	if err != nil || res != ok || calls != 3 {
		t.Fatalf("res %v err %v after %d calls; want success on the third", res, err, calls)
	}

	// The same transaction another relayer submitted first, still pending.
	calls = 0
	dup := errors.New("broadcast tx: Tx already exists in cache")
	if res, err := retrySequence(5, 0, func() (*ctypes.ResultBroadcastTxCommit, error) {
		calls++
		if calls == 1 {
			return nil, dup
		}
		return ok, nil
	}); err != nil || res != ok || calls != 2 {
		t.Fatalf("duplicate: res %v err %v after %d calls", res, err, calls)
	}

	calls = 0
	other := errors.New("deliver tx: insufficient funds")
	if _, err := retrySequence(5, 0, func() (*ctypes.ResultBroadcastTxCommit, error) { calls++; return nil, other }); err != other || calls != 1 {
		t.Fatalf("err %v after %d calls; want the error, once", err, calls)
	}

	calls = 0
	if _, err := retrySequence(5, 0, func() (*ctypes.ResultBroadcastTxCommit, error) { calls++; return nil, stale }); err != stale || calls != 5 {
		t.Fatalf("err %v after %d calls; want the conflict after 5", err, calls)
	}
}
