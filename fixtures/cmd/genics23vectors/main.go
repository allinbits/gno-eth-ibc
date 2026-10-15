// Command genics23vectors converts the official ICS23 test vectors
// (github.com/cosmos/ics23 testdata/{iavl,tendermint,smt}/*.json) into the
// ABI proof format, so the generic Solidity verifier is tested against specs
// other than gno's own. Usage:
//
//	git clone --depth 1 --branch go/v0.11.0 https://github.com/cosmos/ics23 /tmp/ics23
//	go run ./cmd/genics23vectors -in /tmp/ics23/testdata -out ../contracts/test/fixtures/ics23_vectors.json
package main

import (
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"

	ics23 "github.com/cosmos/ics23/go"

	"github.com/gnolang/gno-eth-ibc/fixtures/gnoibc"
)

type refData struct {
	RootRef string `json:"root"`
	Proof   string `json:"proof"`
	Key     string `json:"key"`
	Value   string `json:"value"`
}

type vector struct {
	Spec  string `json:"spec"`
	Name  string `json:"name"`
	Exist bool   `json:"exist"`
	Root  string `json:"root"`
	Key   string `json:"key"`
	Value string `json:"value"`
	Proof string `json:"proof"`
}

func main() {
	in := flag.String("in", "", "ics23 testdata directory")
	out := flag.String("out", "../contracts/test/fixtures/ics23_vectors.json", "output file")
	flag.Parse()

	specs := []struct {
		dir  string
		spec *ics23.ProofSpec
	}{{"iavl", ics23.IavlSpec}, {"tendermint", ics23.TendermintSpec}, {"smt", ics23.SmtSpec}}
	var vectors []vector
	for _, s := range specs {
		for _, name := range []string{"exist_left", "exist_middle", "exist_right", "nonexist_left", "nonexist_middle", "nonexist_right"} {
			bz, err := os.ReadFile(filepath.Join(*in, s.dir, name+".json"))
			if err != nil {
				panic(err)
			}
			var rd refData
			if err := json.Unmarshal(bz, &rd); err != nil {
				panic(err)
			}
			proofBz, _ := hex.DecodeString(rd.Proof)
			root, _ := hex.DecodeString(rd.RootRef)
			key, _ := hex.DecodeString(rd.Key)
			value, _ := hex.DecodeString(rd.Value)
			var cp ics23.CommitmentProof
			if err := cp.Unmarshal(proofBz); err != nil {
				panic(err)
			}
			v := vector{Spec: s.dir, Name: name, Root: "0x" + rd.RootRef, Key: "0x" + rd.Key, Value: "0x" + rd.Value}
			var packed []byte
			if ex := cp.GetExist(); ex != nil {
				if !ics23.VerifyMembership(s.spec, root, &cp, key, value) {
					panic("reference rejects " + s.dir + "/" + name)
				}
				p, err := gnoibc.EncodeExistenceProof(s.spec, ex)
				if err != nil {
					panic(err)
				}
				v.Exist = true
				packed, err = gnoibc.PackExistenceProof(p)
				if err != nil {
					panic(err)
				}
			} else if ne := cp.GetNonexist(); ne != nil {
				if !ics23.VerifyNonMembership(s.spec, root, &cp, key) {
					panic("reference rejects " + s.dir + "/" + name)
				}
				p, err := gnoibc.EncodeNonExistenceProof(s.spec, ne)
				if err != nil {
					panic(err)
				}
				// the vectors leave NonExistenceProof.key unset; the contract checks it
				p.Key = key
				packed, err = gnoibc.PackNonExistenceProof(p)
				if err != nil {
					panic(err)
				}
			} else {
				panic("unexpected proof type")
			}
			v.Proof = "0x" + hex.EncodeToString(packed)
			vectors = append(vectors, v)
		}
	}
	bz, _ := json.MarshalIndent(map[string]any{"vectors": vectors}, "", "  ")
	if err := os.WriteFile(*out, append(bz, '\n'), 0o644); err != nil {
		panic(err)
	}
	fmt.Println("wrote", len(vectors), "vectors to", *out)
}
