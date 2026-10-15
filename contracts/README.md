# GnoLightClient

An IBC v2 light client of a gno.land (tm2) chain for Ethereum, implementing
`ILightClient` from [solidity-ibc-eureka](https://github.com/cosmos/solidity-ibc-eureka)
`solidity-v3.0.2` so it can be registered with that release's `ICS26Router`.

It only accepts validator sets whose consensus keys are **secp256k1** (tm2's
`PubKeySecp256k1`): their commit signatures are checked with `sha256` + `ecrecover`.

## Layout

```
contracts/
  src/GnoLightClient.sol             ILightClient implementation
  src/msgs/IGnoLightClientMsgs.sol   ABI structs of update / misbehaviour / proof messages
  src/errors/IGnoLightClientErrors.sol
  src/lib/Tm2Encoding.sol            the amino encodings the client must reproduce
  src/lib/Tm2Merkle.sol              tm2 simple Merkle tree
  src/lib/ICS23.sol                  generic ICS23 existence / non-existence verifier
  src/lib/GnoProofSpecs.sol          bptree and Tendermint (rootmulti) ProofSpecs
  test/                              Foundry tests; fixtures/ holds JSON made from real tm2 code
  lib/                               forge-std v1.15.0, solidity-ibc-eureka solidity-v3.0.2 (submodules)
fixtures/                            Go: relayer-side encoder (gnoibc) and fixture generators
```

## Running

Foundry runs from its Docker image only (`ghcr.io/foundry-rs/foundry:v1.7.1`):

```
git submodule update --init --recursive
make build        # forge build
make test         # forge test   (FORGE_ARGS="-vv" shows the gas logs)
make gas          # forge test --gas-report
make fmt
make fixtures     # regenerate test/fixtures/gno.json from ../gno (needs Go)
```

`fixtures/go.mod` replaces `github.com/gnolang/gno` with `../../gno`, i.e. a gno checkout next to this
repository (branch `feat/secp256k1-validators-ibc`).

## Messages

Everything is plain `abi.encode` of the structs in `IGnoLightClientMsgs.sol`. `fixtures/gnoibc` builds
them from tm2 types with go-ethereum's `abi` package:

| call | bytes | Go |
|---|---|---|
| constructor | `(ClientState, ConsensusState)` | `PackClientState`, `PackConsensusState` |
| `updateClient` | `abi.encode(Header)` | `EncodeHeader` + `PackHeader` |
| `misbehaviour` | `abi.encode(Misbehaviour)` | `PackMisbehaviour` |
| `verifyMembership` proof | `abi.encode(MembershipProof)` | `EncodeMembershipProof(res.Proof.Ops)` |
| `verifyNonMembership` proof | `abi.encode(NonMembershipProof)` | `EncodeNonMembershipProof(res.Proof.Ops)` |
| `getClientState()` returns | `abi.encode(ClientState)` | |

### Update (`Header`)

```
Header {
  HeaderFields signedHeader {
    uint64 height; uint64 timeSeconds; uint32 timeNanos;
    bytes32 nextValidatorsHash; bytes32 appHash;
    // hashes of the parts of the 16-leaf header tree the contract does not rebuild
    bytes32 versionLeafHash;          // leafHash(leaf 0: Version)
    bytes32 txsAndLastBlockIDHash;    // subtree of leaves 4..7: NumTxs, TotalTxs, AppVersion, LastBlockID
    bytes32 lastCommitAndDataHash;    // subtree of leaves 8..9: LastCommitHash, DataHash
    bytes32 consensusLeafHash;        // leafHash(leaf 12: ConsensusHash)
    bytes32 resultsAndProposerHash;   // subtree of leaves 14..15: LastResultsHash, ProposerAddress
  }
  Commit commit { uint32 round; uint32 partSetTotal; bytes32 partSetHash; CommitSig[] signatures; }
  Validator[] validatorSet;           // { bytes pubKey /* 64-byte X||Y */; uint64 votingPower }, set order
  uint64 trustedHeight;
  Validator[] trustedValidators;      // empty unless non-adjacent with a different validator set
}
CommitSig { uint32 validatorIndex; uint32 trustedIndex; uint64 timeSeconds; uint32 timeNanos;
            bytes32 r; bytes32 s; uint8 v; }
```

The contract amino-encodes the six leaves it relies on itself (ChainID from its client state, Height,
Time, ValidatorsHash computed from `validatorSet`, NextValidatorsHash, AppHash) and recomputes
`Header.Hash()` from them and the five siblings. A relayer therefore cannot make it read one value while
the signatures cover another.

Per signature, the relayer supplies:

* `validatorIndex`: the precommit's index in the commit, which is the index in `validatorSet`. Indices
  must strictly increase (this also rules out counting a signer twice). Only precommits for the
  committed BlockID are sent; absent and nil-block precommits are dropped (dropping can only lower the
  tally).
* `trustedIndex`: the signer's index in `trustedValidators` (`type(uint32).max` if absent), so the trust
  check is a lookup rather than a search.
* `v`: tm2 signatures are 64-byte `r||s` with no recovery id. The relayer finds `v ∈ {27,28}` by trial
  recovery (`gnoibc.RecoveryID`). It is not signed; a wrong `v` just fails.

Verification (`_verifyHeader`), following tm2 and AtomOne's `modules/10-gno` verifier:

1. the consensus state at `trustedHeight` exists, is within the trusting period
   (`trusted.time + trustingPeriod > now`), and `height > trustedHeight`;
2. for updates (not misbehaviour): `trusted.time < header.time < now + maxClockDrift`;
3. each validator's 64-byte key must be on the curve; the contract derives the 33-byte compressed key
   (prefix from Y's parity) for the tm2 hash and `keccak256(X||Y)[12:]` for `ecrecover`;
4. adjacent (`height == trustedHeight + 1`) or no `trustedValidators`: the header's validator set hash
   must equal the trusted `nextValidatorsHash`. Non-adjacent with `trustedValidators`: those must hash to
   the trusted `nextValidatorsHash`, and more than `trustLevel` (default 1/3) of their power must have
   signed (`tallied > total * num / den`);
5. for each signature: rebuild the CanonicalVote sign bytes, require low-S, `ecrecover(sha256(bytes))`
   must be the validator's address; more than 2/3 of the header set's power must sign
   (`tallied > total * 2 / 3`).

`updateClient` then returns `NoOp` if the height already holds the same consensus state, freezes and
returns `Misbehaviour` if it holds a different one (or if the new header's time is not after the latest
one's), and otherwise stores `{timestamp (unix ns), appHash, nextValidatorsHash}` at the height. Updates
only move forward: a new height below `latestHeight` is refused.

### Misbehaviour

`Misbehaviour { Header header1; Header header2; }`. Both headers must verify as above against stored
consensus states (without the clock checks); then either they have the same height and different block
hashes, or `header1.height > header2.height` and `header1.time <= header2.time`. The client is frozen;
every later call reverts with `ClientFrozen`.

### Proofs

gno.land state is two ICS23 proofs deep: the key in the `main` store (a B+tree, ProofOp `ics23:bptree`,
spec `tm2/pkg/bptree/proof_spec.go`), then the `main` store root in the rootmulti AppHash (ProofOp
`ics23:simple`, ICS23 `TendermintSpec`). These are the two ops an ABCI query `/.store/main/key` (or
`/main/key` on the multistore) with `prove=true` returns, in that order.

```
ExistenceProof    { bytes key; bytes value; bytes leafPrefix; InnerOp[] path; }   // InnerOp { bytes prefix; bytes suffix; }
NonExistenceProof { bytes key; ExistenceProof left; ExistenceProof right; }       // empty key = no neighbour
MembershipProof    { ExistenceProof storeProof;    ExistenceProof rootProof; }
NonMembershipProof { NonExistenceProof storeProof; ExistenceProof rootProof; }
```

Ops carry only their variable parts; the hash, prehash and length operations come from the spec (ICS23
rejects a proof whose ops differ from its spec, so nothing is lost; the Go encoder refuses such proofs).
`ICS23.sol` ports `cosmos/ics23/go` v0.11.0: spec checks (leaf prefix, inner prefix bounds, suffix
alignment, min/max depth), leaf and inner hashing, key ordering (with optional prehash before
comparison) and the left-most / right-most / neighbour checks including `EmptyChild` padding. It is
tested against the official IAVL, Tendermint and SMT vectors as well as gno's proofs. Not ported:
IAVL-specific op validation, batch/compressed proofs, and hashes without an EVM precompile.

`path` must have two elements, as the router builds them from the counterparty merkle prefix
`["main", "/pv/vm:gno.land/r/aib/ibc/core:"]` with the IBC key appended to the last one:
`path[1] = "/pv/vm:gno.land/r/aib/ibc/core:" || clientId || 0x01|0x02|0x03 || uint64_be(sequence)`.
`value` is what the realm stored with `params.SetBytes`, raw: the 32-byte packet / ack commitment. Both
calls return the consensus timestamp in seconds. They revert if the client is frozen or expired (latest
consensus state older than the trusting period), if the revision number differs, or if no consensus
state exists at the proof height.

A relayer must prove against the right header: tm2's header `H` carries the AppHash of the state
committed at `H-1`, so a query at store version `v` verifies against the consensus state of height
`v+1`.

## tm2 formats, as checked against the Go source

Every encoding below is also asserted byte-for-byte in `test/Tm2Encoding.t.sol` against output of the
real Go code (`fixtures/cmd/genfixtures`). References are to the gno repository.

* `Header.Hash` (`tm2/pkg/bft/types/block.go:311`): 16 leaves, each `amino.MustMarshal(field)` or empty
  when the field is empty (`encoding_helper.go:9`). Top-level amino wraps primitives as field 1:
  ChainID → `0a len bytes`, Height → `08 zigzag-varint(h)` (int64 is zigzag: 11 → `08 16`), hashes →
  `0a 20 <32 bytes>`. The Time leaf is the bare timestamp struct `08 uvarint(seconds) 10 uvarint(nanos)`
  (seconds plain varint, zero fields omitted), without a field-1 wrapper. ProposerAddress encodes as its
  bech32 string (only ever a sibling hash here).
* Simple Merkle (`tm2/pkg/crypto/merkle/simple_tree.go:9`, `hash.go:14`): `sha256(0x00||leaf)`,
  `sha256(0x01||l||r)`, split at the largest power of two below n.
* Vote sign bytes (`vote.go:73`, `canonical.go:41`, `block.go:453,480`): `MarshalSized(CanonicalVote)`:
  uvarint length, `08 02` (precommit), `11 <height LE fixed64>`, `19 <round LE fixed64>` omitted when
  round is 0, `22 len {0a 20 hash, 12 len {08 uvarint(total), 12 20 partsHash}}` (Total is uint32,
  `canonical.go:26`), `2a len <timestamp>`, `32 len chainID`. Each precommit has its own timestamp and
  BlockID; only those for the committed BlockID count.
* secp256k1 (`tm2/pkg/crypto/secp256k1/secp256k1_nocgo.go:15,26,57`): signs `sha256(msg)`, signature
  `r||s` (64 bytes), verification rejects high S.
* Validator hash (`validator.go:88`, `validator_set.go:309`): leaf =
  `0a 3a | 0a 13 "/tm.PubKeySecp256k1" | 12 23 | 0a 21 <33-byte key>` then `10 zigzag-varint(power)`
  (power 10 → `10 14`).
* Commit checks (`validator_set.go:632-673`): `tallied > total*2/3` with integer division. tm2's own
  `VerifyFutureCommit` (`validator_set.go:704`) wants >2/3 of the old set; the light client uses the
  trust level instead, as AtomOne's `10-gno` `VerifyNonAdjacent`/`VerifyLightCommit` does.
* Store: gno.land mounts `main` as the bptree fast store and the params keeper on it
  (`gno.land/pkg/gnoland/app.go:94,113,118`). Params live under `/pv/` + key
  (`tm2/pkg/sdk/params/keeper.go:20`), realm params under `vm:<realm>:<key>`
  (`gnovm/stdlibs/chain/params/params.go:98`), and `SetBytes` stores the bytes raw
  (`keeper.go:172`). The multistore root is `SimpleHashFromMap` of store name → store hash
  (`tm2/pkg/store/rootmulti/store.go:667`, leaves `uvarint-len key || uvarint-len sha256(value)`,
  `tm2/pkg/crypto/merkle/simple_map.go:34,75`), proven with `ProofOpFromMap` (`types/ics23.go:144`).
  The bptree's `EmptyChild` is `sha256(0x02)` (`tm2/pkg/bptree/const.go:27,75`).
* The realm stores receipts as the single byte `0x02`; the router only ever proves receipts absent.

## Gas

Execution gas from `forge test -vv` (`vm.lastCallGas`), first update of the client in the transaction
(cold storage). A standalone transaction adds 21,000 plus calldata (~2 KB for a 3-validator update).

| call | gas |
|---|---|
| `updateClient`, adjacent, 3 validators, 3 signatures | ~171k |
| `updateClient`, adjacent, 4 validators, 3 signatures | ~165k (warm client state) |
| `updateClient`, non-adjacent, 3 trusted + 4 new validators, 4 signatures | ~207k |
| `misbehaviour`, two 3-validator headers | ~188k |
| `verifyMembership` (15-step bptree + rootmulti proof) | ~70k |
| `verifyNonMembership`, key between two neighbours | ~180k |
| `verifyNonMembership`, key before / after every key (one neighbour) | ~77k–95k |

## Limitations

* Forward-only updates: no backfilling heights below `latestHeight`, so no time-monotonicity check
  against a next consensus state is needed.
* No consensus state pruning and no client upgrades / recovery.
* The chain ID is fixed; there is no revision-format handling (`revisionNumber` is a constant of the
  client state that every proof height must carry).
* Validator sets are passed in full on every update; with large sets, calldata grows linearly.
