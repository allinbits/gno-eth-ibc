package relay

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gnolang/gno/gnovm/stdlibs/chain"
	abci "github.com/gnolang/gno/tm2/pkg/bft/abci/types"
	rpcclient "github.com/gnolang/gno/tm2/pkg/bft/rpc/client"
	ctypes "github.com/gnolang/gno/tm2/pkg/bft/rpc/core/types"
	rpctypes "github.com/gnolang/gno/tm2/pkg/bft/rpc/lib/types"
	"github.com/gnolang/gno/tm2/pkg/bft/state"
	"github.com/gnolang/gno/tm2/pkg/crypto/merkle"
	"google.golang.org/protobuf/encoding/protowire"

	"github.com/gnolang/gno-eth-ibc/relayer/arc"
	"github.com/gnolang/gno-eth-ibc/relayer/eth"
	"github.com/gnolang/gno-eth-ibc/relayer/gno"
	"github.com/gnolang/gno-eth-ibc/relayer/ibc"
)

// fakeGno serves the RPC methods the relayer reads gno state with: status
// (latest height 7), abci_query (store keys, from store, at any height) and
// block_results (blocks). Any other query fails, so a test sees whether the
// relayer went further.
func fakeGno(t *testing.T, store map[string][]byte, blocks ...map[int64][]abci.Event) *gno.Client {
	return fakeGnoRender(t, store, nil, blocks...)
}

// fakeGnoRender is fakeGno also answering vm/qeval of the core realm's
// Render(path) with renders[path].
func fakeGnoRender(t *testing.T, store map[string][]byte, renders map[string]string, blocks ...map[int64][]abci.Event) *gno.Client {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		body, _ := io.ReadAll(req.Body)
		var r rpctypes.RPCRequest
		if err := json.Unmarshal(body, &r); err != nil {
			t.Errorf("request %s: %v", body, err)
			return
		}
		var res rpctypes.RPCResponse
		switch r.Method {
		case "status":
			st := ctypes.ResultStatus{}
			st.SyncInfo.LatestBlockHeight = 7
			res = rpctypes.NewRPCSuccessResponse(r.ID, &st)
		case "abci_query":
			var p struct {
				Path   string `json:"path"`
				Data   string `json:"data"`
				Height int64  `json:"height,string"`
			}
			if err := json.Unmarshal(r.Params, &p); err != nil {
				t.Errorf("params %s: %v", r.Params, err)
				return
			}
			if p.Path == "vm/qeval" {
				expr, err := hex.DecodeString(p.Data)
				if err != nil {
					expr, _ = base64.StdEncoding.DecodeString(p.Data)
				}
				var out []byte
				for path, js := range renders {
					if string(expr) == gno.CoreRealm+"."+"Render("+strconv.Quote(path)+")" {
						out = []byte("(" + strconv.Quote(js) + " string)")
					}
				}
				q := ctypes.ResultABCIQuery{Response: abci.ResponseQuery{ResponseBase: abci.ResponseBase{Data: out}, Height: 7}}
				res = rpctypes.NewRPCSuccessResponse(r.ID, &q)
				break
			}
			if !strings.HasPrefix(p.Path, ".store/") {
				res = rpctypes.RPCInternalError(r.ID, io.ErrUnexpectedEOF)
				break
			}
			key, err := hex.DecodeString(p.Data)
			if err != nil {
				if key, err = base64.StdEncoding.DecodeString(p.Data); err != nil {
					t.Errorf("data %q", p.Data)
					return
				}
			}
			q := ctypes.ResultABCIQuery{Response: abci.ResponseQuery{
				Key: key, Value: store[string(key)], Height: p.Height, Proof: &merkle.Proof{Ops: []merkle.ProofOp{}},
			}}
			if q.Response.Height == 0 {
				q.Response.Height = 7
			}
			res = rpctypes.NewRPCSuccessResponse(r.ID, &q)
		case "block_results":
			var p struct {
				Height int64 `json:"height,string"`
			}
			_ = json.Unmarshal(r.Params, &p)
			br := ctypes.ResultBlockResults{Height: p.Height, Results: &state.ABCIResponses{}}
			for _, b := range blocks {
				if evs, ok := b[p.Height]; ok {
					br.Results.DeliverTxs = []abci.ResponseDeliverTx{{ResponseBase: abci.ResponseBase{Events: evs}}}
				}
			}
			res = rpctypes.NewRPCSuccessResponse(r.ID, &br)
		default:
			res = rpctypes.RPCMethodNotFoundError(r.ID)
		}
		_ = json.NewEncoder(w).Encode(res)
	}))
	t.Cleanup(srv.Close)
	rpc, err := rpcclient.NewHTTPClient(srv.URL)
	if err != nil {
		t.Fatal(err)
	}
	return &gno.Client{RPC: rpc}
}

var arcPacket = ibc.Packet{SourceClient: "07-tendermint-0", DestinationClient: "arc-0", Sequence: 9}

// A packet gno holds a receipt for was received by an earlier run: relaying
// it again would be a no-op that writes no acknowledgement.
func TestGnoReceived(t *testing.T) {
	g := fakeGno(t, map[string][]byte{string(ReceiptKey("arc-0", 9)): {2}})
	got, err := gnoReceived(context.Background(), g, arcPacket)
	if err != nil || !got {
		t.Fatalf("received %v, %v; want true", got, err)
	}
	other := arcPacket
	other.Sequence = 10
	if got, err := gnoReceived(context.Background(), g, other); err != nil || got {
		t.Fatalf("sequence 10 received %v, %v; want false", got, err)
	}
}

// The receipt key is the core's host.PacketReceiptKey under the params prefix.
func TestReceiptKey(t *testing.T) {
	want := append([]byte(gno.ParamsPrefix), append([]byte("arc-0\x02"), 0, 0, 0, 0, 0, 0, 0, 9)...)
	if got := ReceiptKey("arc-0", 9); !bytes.Equal(got, want) {
		t.Fatalf("got %q\nwant %q", got, want)
	}
}

// Arc's ack of a packet gno already acknowledged (gno's commitment gone) is
// skipped before any client update; one gno still awaits goes on to update
// the client, which this fake refuses.
func TestArcRelayAckSkipsAcknowledged(t *testing.T) {
	sent := ibc.Packet{SourceClient: "arc-0", DestinationClient: "07-tendermint-0", Sequence: 4}
	w := WrittenAck{Packet: sent, Acks: [][]byte{{1}}}
	log := slog.New(slog.NewTextHandler(io.Discard, nil))

	r := &ArcToGno{Gno: fakeGno(t, nil), GnoClientID: "arc-0", Log: log}
	if err := r.RelayAck(context.Background(), w); err != nil {
		t.Fatalf("acknowledged packet: %v", err)
	}

	// An Arc RPC that answers nothing: reaching it means the ack was not
	// skipped.
	down := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, "down", http.StatusServiceUnavailable)
	}))
	t.Cleanup(down.Close)
	a, err := arc.Dial(context.Background(), down.URL, down.URL)
	if err != nil {
		t.Fatal(err)
	}
	pending := map[string][]byte{string(gno.PacketCommitmentKey("arc-0", 4)): bytes.Repeat([]byte{1}, 32)}
	r = &ArcToGno{Gno: fakeGno(t, pending), Arc: a, GnoClientID: "arc-0", Log: log}
	if err := r.RelayAck(context.Background(), w); err == nil {
		t.Fatal("a pending packet's ack was skipped")
	}
}

// The relayer proves the registry the client reads, which a recovery may
// have moved to another storage location: it comes from the client state.
func TestParseArcClientRegistry(t *testing.T) {
	addr := bytes.Repeat([]byte{0x36}, 20)
	loc := bytes.Repeat([]byte{0xaa}, 32)
	b64 := base64.StdEncoding.EncodeToString
	js := `{"client_state":{"registry_address":"` + b64(addr) + `","registry_storage_location":"` + b64(loc) + `"},` +
		`"last_consensus_state":{"height":{"revision_height":120},"registry_storage_root":"` + b64(bytes.Repeat([]byte{7}, 32)) + `"}}`
	h, root, reg, err := parseArcClient("arc-0", js)
	if err != nil {
		t.Fatal(err)
	}
	if h != 120 || root[0] != 7 || !bytes.Equal(reg.Address[:], addr) || !bytes.Equal(reg.StorageLocation[:], loc) {
		t.Fatalf("height %d root %x registry %+v", h, root, reg)
	}
	bad := strings.Replace(js, b64(loc), b64(loc[:31]), 1)
	if _, _, _, err := parseArcClient("arc-0", bad); err == nil {
		t.Fatal("a 31-byte storage location was accepted")
	}
	if _, _, _, err := parseArcClient("arc-0", `{"last_consensus_state":{}}`); err == nil {
		t.Fatal("a render without a client state was accepted")
	}
}

// sendPacketEvent is the core's send_packet event for p.
func sendPacketEvent(p ibc.Packet) abci.Event {
	var bz []byte
	bz = protowire.AppendTag(bz, 1, protowire.VarintType)
	bz = protowire.AppendVarint(bz, p.Sequence)
	bz = protowire.AppendTag(bz, 2, protowire.BytesType)
	bz = protowire.AppendString(bz, p.SourceClient)
	bz = protowire.AppendTag(bz, 3, protowire.BytesType)
	bz = protowire.AppendString(bz, p.DestinationClient)
	return chain.Event{Type: gno.EventSendPacket, PkgPath: gno.CoreRealm, Attributes: []chain.EventAttribute{
		{Key: gno.AttrEncodedPacketHex, Value: hex.EncodeToString(bz)},
	}}
}

// A restarted gno -> EVM relayer skips the packets gno already settled
// (acknowledged or timed out, so their commitment is gone) instead of
// failing to prove them, and pays for no update when none is left. Eth is
// nil here: reaching the update or the EVM chain would panic.
func TestGnoToEthSkipsSettled(t *testing.T) {
	p := ibc.Packet{SourceClient: "arc-0", DestinationClient: "client-0", Sequence: 3}
	g := fakeGno(t, nil, map[int64][]abci.Event{5: {sendPacketEvent(p)}})
	r := &GnoToEth{Gno: g, GnoClientID: "arc-0", Log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	out, err := r.RelayRange(context.Background(), 5, 5)
	if err != nil || len(out) != 0 {
		t.Fatalf("relayed %v, %v; want nothing", out, err)
	}
}

// An ack seen at block 12 is proven only once the proof RPC reaches 12: a
// lagging RPC is waited for, and one that never gets there is an error.
func TestWaitBlock(t *testing.T) {
	at := uint64(10)
	calls := 0
	lagging := func(context.Context) (uint64, error) { calls++; at++; return at, nil }
	if err := waitBlock(context.Background(), lagging, 12, 5, 0); err != nil || calls != 2 {
		t.Fatalf("err %v after %d polls; want block 12 on the second", err, calls)
	}
	stuck := func(context.Context) (uint64, error) { return 3, nil }
	if err := waitBlock(context.Background(), stuck, 12, 3, 0); err == nil {
		t.Fatal("a proof RPC stuck before the block was accepted")
	}
}

// Another relayer moved gno's Arc client to block 102 while this relayer's
// proof RPC still serves 101: the update waits until the RPC serves a block
// past 102 before reading any proof, rather than snapshotting 101 and
// stopping.
func TestArcUpdateWaitsForTheTrustedHeight(t *testing.T) {
	b64 := base64.StdEncoding.EncodeToString
	render := `{"client_state":{"registry_address":"` + b64(arc.RegistryAddress[:]) + `","registry_storage_location":"` + b64(arc.RegistryStorageLocation[:]) + `"},` +
		`"last_consensus_state":{"height":{"revision_height":102},"registry_storage_root":"` + b64(make([]byte, 32)) + `"}}`
	g := fakeGnoRender(t, nil, map[string]string{"clients/arc-0": render})

	var polls, proofsAt atomic.Int64
	heights := []uint64{101, 101, 103}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		var r struct {
			ID     json.RawMessage `json:"id"`
			Method string          `json:"method"`
		}
		_ = json.NewDecoder(req.Body).Decode(&r)
		w.Header().Set("Content-Type", "application/json")
		switch r.Method {
		case "eth_blockNumber":
			n := polls.Add(1)
			h := heights[min(int(n), len(heights))-1]
			_, _ = w.Write([]byte(`{"jsonrpc":"2.0","id":` + string(r.ID) + `,"result":"0x` + strconv.FormatUint(h, 16) + `"}`))
		default: // eth_getProof: note when, then fail the snapshot
			proofsAt.CompareAndSwap(0, polls.Load())
			_, _ = w.Write([]byte(`{"jsonrpc":"2.0","id":` + string(r.ID) + `,"error":{"code":-32000,"message":"stop"}}`))
		}
	}))
	t.Cleanup(srv.Close)
	a, err := arc.Dial(context.Background(), srv.URL, srv.URL)
	if err != nil {
		t.Fatal(err)
	}
	r := &ArcToGno{Gno: g, Arc: a, Eth: &eth.Client{Dep: &eth.Deployment{}}, GnoClientID: "arc-0",
		Log: slog.New(slog.NewTextHandler(io.Discard, nil)), BlockWait: time.Millisecond}
	if _, err := r.SnapshotAndUpdate(context.Background(), nil); err == nil || !strings.Contains(err.Error(), "stop") {
		t.Fatalf("err %v; want the fake's proof error", err)
	}
	if got := proofsAt.Load(); got != 3 {
		t.Fatalf("first proof read after %d block polls; want 3 (once the RPC passed 102)", got)
	}
}
