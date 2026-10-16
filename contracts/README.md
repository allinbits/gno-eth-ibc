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
    bytes32 validatorsHash; bytes32 nextValidatorsHash; bytes32 appHash;
    // hashes of the parts of the 16-leaf header tree the contract does not rebuild
    bytes32 versionLeafHash;          // leafHash(leaf 0: Version)
    bytes32 txsAndLastBlockIDHash;    // subtree of leaves 4..7: NumTxs, TotalTxs, AppVersion, LastBlockID
    bytes32 lastCommitAndDataHash;    // subtree of leaves 8..9: LastCommitHash, DataHash
    bytes32 consensusLeafHash;        // leafHash(leaf 12: ConsensusHash)
    bytes32 resultsAndProposerHash;   // subtree of leaves 14..15: LastResultsHash, ProposerAddress
  }
  Commit commit { uint32 round; uint32 partSetTotal; bytes32 partSetHash; bytes signatures; }
  Validator[] validatorSet;           // { bytes pubKey /* 64-byte X||Y */; uint64 votingPower }, set order;
                                      // empty when the set is cached
  uint64 trustedHeight;
  Validator[] trustedValidators;      // only for a non-adjacent header with another set, and only if not cached
}
signatures = CommitSig || CommitSig || ...   // 81 bytes each, big-endian:
  u16 validatorIndex | u16 trustedIndex (0xffff: none) | u64 timeSeconds | u32 timeNanos | r (32) | s (32) | u8 v
```

The contract amino-encodes the six leaves it relies on itself (ChainID from its client state, Height,
Time, ValidatorsHash, NextValidatorsHash, AppHash) and recomputes `Header.Hash()` from them and the five
siblings. A relayer therefore cannot make it read one value while the signatures cover another.

**Validator set cache.** The client keeps validator sets in storage keyed by their tm2
`ValidatorSet.Hash`: per validator `(power << 160) | address`, plus size and total power. A set is
cached only from supplied keys and powers whose hash the contract recomputed (on-curve keys, the exact
tm2 encoding), and only when an accepted update's header has that set as its *next* set as well, i.e.
when the next update will need it. Since the hash commits to the keys and powers, a cached entry is the
set the hash names; a header naming a cached set by `validatorsHash` gets exactly that set, and any
other claim changes the header hash and fails the signatures. `isValidatorSetCached(hash)` and
`getValidatorSet(hash)` expose the cache; misbehaviour submissions never write it.

Per signature, the relayer supplies:

* `validatorIndex`: the precommit's index in the commit, which is the index in the validator set.
  Indices must strictly increase (this also rules out counting a signer twice). Only precommits for the
  committed BlockID are sent; the relayer sends the fewest that clear the thresholds (highest power
  first; for a trust check, first the signers with the most trusted power). Dropping signatures can only
  lower the tally.
* `trustedIndex`: the signer's index in the trusted set (`0xffff` if absent or no trust check), so the
  trust check is a lookup rather than a search.
* `v`: tm2 signatures are 64-byte `r||s` with no recovery id. The relayer finds `v ∈ {27,28}` by trial
  recovery (`gnoibc.RecoveryID`). It is not signed; a wrong `v` just fails.

Verification (`_verifyHeader`), following tm2 and AtomOne's `modules/10-gno` verifier:

1. the consensus state at `trustedHeight` exists, is within the trusting period
   (`trusted.time + trustingPeriod > now`), and `height > trustedHeight`;
2. for updates (not misbehaviour): `trusted.time < header.time < now + maxClockDrift`;
3. the header's validator set: supplied keys (each on the curve; the contract derives the 33-byte
   compressed key for the tm2 hash and `keccak256(X||Y)[12:]` for `ecrecover`) must hash to
   `validatorsHash`, or the set cached under `validatorsHash` is used;
4. if `validatorsHash` equals the trusted `nextValidatorsHash`, no trust check is needed. Otherwise the
   header must be non-adjacent, and more than `trustLevel` (default 1/3) of the trusted next set's power
   must have signed (`tallied > total * num / den`), the set coming from `trustedValidators` (hashing to
   the trusted `nextValidatorsHash`) or the cache;
5. for each signature: rebuild the CanonicalVote sign bytes in one reused buffer, require low-S,
   `ecrecover(sha256(bytes))` must be the validator's address; more than 2/3 of the header set's power
   must sign (`tallied > total * 2 / 3`).

`updateClient` then returns `NoOp` if the height already holds the same consensus state, freezes and
returns `Misbehaviour` if it holds a different one (or if the new header's time is not after the latest
one's), and otherwise stores `{timestamp (unix ns), appHash, nextValidatorsHash}` at the height and caches
the supplied validator set if it is also the next set. Updates only move forward: a new height below
`latestHeight` is refused.

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

## Deployment

`script/DeployGnoIBC.s.sol` deploys, in eureka v3.0.2's `E2ETestDeploy` order: an `AccessManager`,
`ICS26Router` and `ICS20Transfer` behind ERC1967 proxies (`ICS20Transfer.initialize` creates the
Escrow and IBCERC20 beacons), the eureka role map (relaying public unless `RELAYER_ADDRESS` is set),
ICS20 on port `transfer`, then `GnoLightClient` from a trusted gno header and
`ICS26Router.addClient` with counterparty `{GNO_COUNTERPARTY_CLIENT_ID, ["main",
"/pv/vm:gno.land/r/aib/ibc/core:"]}`. The extra dependencies (OpenZeppelin contracts and
contracts-upgradeable v5.6.1, permit2 at eureka's pinned commit) are submodules under `lib/`.

```
relayer trust -gno-rpc http://127.0.0.1:26657 -out contracts/deployments/trust.json
DEPLOYER_PRIVATE_KEY=0x... GNO_COUNTERPARTY_CLIENT_ID=ethereum-1 \
  forge script script/DeployGnoIBC.s.sol --rpc-url $ETH_RPC_URL --broadcast
```

Addresses are written to `deployments/<chainid>.json` (or `DEPLOYMENTS_FILE`). `make e2e-local` runs
the whole local flow; see `../scripts/e2e-local.sh`.

### Vouchers of gno.land denoms

ICS20 carries amounts in base units. On first receipt of a denom, `ICS20Transfer` deploys an
`IBCERC20` voucher whose `decimals()` is 18 and cannot be changed, so 1 GNOT (1,000,000 ugnot) would
show in wallets as 10^-12 tokens. Each gno.land denom therefore gets a `GnoVoucher`
(`src/GnoVoucher.sol`): an ERC20 with the denom's name, symbol and gno.land decimals that only
`ICS20Transfer` mints and burns, registered with `ICS20Transfer.setCustomERC20` before the denom's
first transfer. Amounts are never scaled.

The deploy script registers ugnot (`Gno.land`, `GNOT`, 6 decimals) as `transfer/<clientId>/ugnot`,
recorded as `ugnotVoucher`, and grants the deployer `ERC20_CUSTOMIZER_ROLE`. Register other denoms,
such as GRC20 tokens, before anyone sends them:

```
DEPLOYER_PRIVATE_KEY=0x... GNO_DENOM=gno.land/r/demo/foo VOUCHER_NAME=Foo VOUCHER_SYMBOL=FOO \
  VOUCHER_DECIMALS=4 forge script script/RegisterGnoDenom.s.sol --rpc-url $ETH_RPC_URL --broadcast
```

A denom sent before it is registered gets an 18-decimal `IBCERC20` for good: `setCustomERC20`
refuses a denom that already has a token.

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

Execution gas from `forge test -vv` (`vm.lastCallGas`). A standalone transaction adds 21,000 plus calldata.

| call | gas |
|---|---|
| `updateClient`, adjacent, 3 validators supplied and cached, 3 signatures | ~248k |
| `updateClient`, adjacent, 4 validators supplied and cached, 3 signatures | ~264k |
| `updateClient`, non-adjacent, 3 trusted + 4 new validators supplied, 4 signatures (4 cached) | ~301k |
| `misbehaviour`, two 3-validator headers | ~160k |
| `verifyMembership` (15-step bptree + rootmulti proof) | ~70k |
| `verifyNonMembership`, key between two neighbours | ~180k |
| `verifyNonMembership`, key before / after every key (one neighbour) | ~77k–95k |

### Scaling with the validator set

`test/GasScaling.t.sol` (`make test FORGE_ARGS="--match-contract GasScaling -vv"`) replays fixtures of
equal-power secp256k1 sets built with tm2 (`fixtures/cmd/genfixtures`, `test/fixtures/gas.json`). Every
measured call starts from cold storage (`vm.cool`). "tx" is 21,000 + calldata (16 gas per non-zero byte,
4 per zero byte of the `updateClient(bytes)` calldata) + execution. "Fewest" is the minimal signer set
the relayer sends (here `floor(2N/3) + 1`).

Steady state, a set that is already cached (the common case: validator sets change rarely):

| N | old: keys, all sign | old: keys, fewest | **cached, fewest** | cached, all sign | calldata (cached, fewest) |
|---:|---:|---:|---:|---:|---:|
| 3 | 194,181 | 194,181 | **170,709** | 170,709 | 1,060 B |
| 7 | 289,511 | 262,171 | **189,309** | 207,878 | 1,220 B |
| 20 | 601,919 | 518,740 | **272,858** | 328,638 | 1,956 B |
| 50 | 1,334,695 | 1,110,009 | **458,773** | 607,494 | 3,588 B |
| 100 | 2,595,664 | 2,120,470 | **765,681** | 1,073,139 | 6,244 B |

(est. tx gas; "old" is the client before the cache and packed signatures, same fixtures.)

All cases, est. tx gas (execution gas / calldata bytes in parentheses):

| N | keys, all sign, no caching | keys, fewest, no caching | keys, fewest, set gets cached | cached, all | cached, fewest | non-adjacent, cached same set, fewest | non-adjacent, 1 validator rotated (keys, cached), trust over cached set |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 3 | 193,088 (156,628 / 1,636) | 193,088 | 284,210 (247,750) | 170,709 (139,037 / 1,060) | 170,709 | 170,629 | 294,738 (258,338) |
| 7 | 262,899 (215,163 / 2,724) | 248,607 | 428,909 (383,613) | 207,878 (171,266 / 1,380) | 189,309 | 189,281 | 444,902 (399,714) |
| 20 | 491,319 (406,827 / 6,276) | 448,032 | 918,412 (841,324) | 328,638 (276,030 / 2,436) | 272,858 | 272,954 | 958,856 (881,960) |
| 50 | 1,024,991 (855,759 / 14,468) | 908,915 | 2,048,531 (1,898,999) | 607,494 (517,846 / 4,868) | 458,773 | 458,789 | 2,146,570 (1,997,458) |
| 100 | 1,935,954 (1,625,582 / 28,132) | 1,693,076 | 3,948,272 (3,678,568) | 1,073,139 (921,851 / 8,932) | 765,681 | 765,841 | 4,135,089 (3,866,177) |

Marginal costs (transaction gas):

* a signature: ~14.3k before, now ~9.2k with the set cached (a cold storage read of the entry, 2,100,
  instead of carrying and hashing the key; 81 instead of 224 calldata bytes) and ~7.3k with keys supplied
  (packed signature, reused sign-bytes buffer);
* a validator whose keys are supplied: ~10.7k (about as before); with the set cached: 0;
* caching a set: ~22.6k per validator once (a new storage slot), paid by the update whose header shows
  the set as its next set as well; it pays for itself after about three updates;
* a trust check over a cached set: one cold storage read per trusted signer.

The rotated case caches the new set (its next set is itself), hence its cost.

## Limitations

* Forward-only updates: no backfilling heights below `latestHeight`, so no time-monotonicity check
  against a next consensus state is needed.
* No consensus state pruning and no client upgrades / recovery.
* The chain ID is fixed; there is no revision-format handling (`revisionNumber` is a constant of the
  client state that every proof height must carry).
* Validator sets are passed in full on every update; with large sets, calldata grows linearly.
