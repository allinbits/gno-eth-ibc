package main

import (
	"encoding/binary"
	"fmt"

	abci "github.com/gnolang/gno/tm2/pkg/bft/abci/types"
	bft "github.com/gnolang/gno/tm2/pkg/bft/types"
	"github.com/gnolang/gno/tm2/pkg/crypto/merkle"
	"github.com/gnolang/gno/tm2/pkg/db/memdb"
	"github.com/gnolang/gno/tm2/pkg/log"
	"github.com/gnolang/gno/tm2/pkg/sdk"
	"github.com/gnolang/gno/tm2/pkg/sdk/params"
	"github.com/gnolang/gno/tm2/pkg/store"
	storebptree "github.com/gnolang/gno/tm2/pkg/store/bptree"
	"github.com/gnolang/gno/tm2/pkg/store/dbadapter"
	"github.com/gnolang/gno/tm2/pkg/store/rootmulti"
	"github.com/gnolang/gno/tm2/pkg/store/types"
)

const (
	realmPath   = "gno.land/r/aib/ibc/core"
	storeName   = "main"
	clientID    = "eth-0"
	paramPrefix = "/pv/vm:" + realmPath + ":" // tm2/pkg/sdk/params/keeper.go storeKey + gnovm stdlibs/chain/params pkey
)

// noopKeeper stands in for the VM keeper's param hook.
type noopKeeper struct{}

func (noopKeeper) WillSetParam(sdk.Context, string, any) {}

// packetKey mirrors gno.land/p/aib/ibc/host/v0 PacketCommitmentKey & co, and
// ICS24Host.packet*PathCalldata on the Solidity side.
func packetKey(clientID string, kind byte, seq uint64) []byte {
	var be [8]byte
	binary.BigEndian.PutUint64(be[:], seq)
	return append(append([]byte(clientID), kind), be[:]...)
}

type gnoStore struct {
	ms      types.CommitMultiStore
	version int64
	appHash []byte
}

// buildStore lays the main and base stores out exactly like gno.land's app
// (gno.land/pkg/gnoland/app.go: main = bptree fast store, base = dbadapter)
// and writes the IBC packet state through the real params keeper, as the
// realm's params.SetBytes does.
func buildStore(entries map[string][]byte) (*gnoStore, error) {
	db := memdb.NewMemDB()
	mainKey := store.NewStoreKey(storeName)
	baseKey := store.NewStoreKey("base")
	ms := store.NewCommitMultiStore(db)
	ms.MountStoreWithDB(mainKey, storebptree.FastStoreConstructor, db)
	ms.MountStoreWithDB(baseKey, dbadapter.StoreConstructor, db)
	if err := ms.LoadLatestVersion(); err != nil {
		return nil, err
	}
	prmk := params.NewParamsKeeper(mainKey)
	prmk.Register("vm", noopKeeper{})
	prmk.Register("bank", noopKeeper{})
	ctx := sdk.NewContext(sdk.RunTxModeDeliver, ms, &bft.Header{Height: 1, ChainID: chainID}, log.NewNoopLogger())

	for k, v := range entries {
		prmk.SetBytes(ctx, "vm:"+realmPath+":"+k, v)
	}
	// unrelated state around the IBC keys, so proofs have real neighbours
	for i := 0; i < 300; i++ {
		prmk.SetBytes(ctx, fmt.Sprintf("bank:filler-%04d", i), []byte{byte(i), 1})
		prmk.SetBytes(ctx, fmt.Sprintf("vm:gno.land/r/other/realm:k%04d", i), []byte{byte(i), 2})
		ctx.Store(mainKey).Set(ctx.GasContext(), []byte(fmt.Sprintf("/acc/%04d", i)), []byte{byte(i), 3})
	}
	cid := ms.Commit()
	return &gnoStore{ms: ms, version: cid.Version, appHash: cid.Hash}, nil
}

// prove runs the ABCI query a relayer would send ("/main/key", prove=true)
// and checks the result with tm2's own proof runtime before returning it.
func (s *gnoStore) prove(key []byte) (value []byte, ops []merkle.ProofOp, err error) {
	res := s.ms.(types.Queryable).Query(abci.RequestQuery{Path: "/" + storeName + "/key", Data: key, Height: s.version, Prove: true})
	if res.Error != nil {
		return nil, nil, res.Error
	}
	prt := rootmulti.DefaultProofRuntime()
	kp := merkle.KeyPath{}.AppendKey([]byte(storeName), merkle.KeyEncodingHex).AppendKey(key, merkle.KeyEncodingHex)
	if res.Value != nil {
		err = prt.VerifyValue(res.Proof, s.appHash, kp.String(), res.Value)
	} else {
		err = prt.VerifyAbsence(res.Proof, s.appHash, kp.String())
	}
	if err != nil {
		return nil, nil, fmt.Errorf("tm2 proof runtime rejected its own proof: %w", err)
	}
	return res.Value, res.Proof.Ops, nil
}
