# gno.land ⇄ Ethereum IBC — working context

State of the work as of 2026-10-16, for picking it up later. `README.md` and `contracts/README.md` describe
the project; this document records where everything lives, what was decided and why, what was measured,
and what is still open.

## Goal

IBC v2 (Eureka) between a gno.land chain and Ethereum, with a light client on each side and no trusted
party:

- **gno.land validators sign with secp256k1** instead of ed25519, so Ethereum can verify gno commits
  cheaply with `ecrecover`: `GnoLightClient.sol` behind solidity-ibc-eureka's ICS26 router.
- **gno.land runs an Ethereum light client** (Altair sync protocol through Electra, Fulu and Gloas) in Gno,
  with the sync committee's BLS aggregate signature checked by a native, and storage proven with
  Merkle-Patricia proofs: in [allinbits/gno-realms](https://github.com/allinbits/gno-realms).
- ICS20 transfers in both directions, relayed by the Go relayer here and by the TypeScript relayer
  ([allinbits/ibc-v2-ts-relayer](https://github.com/allinbits/ibc-v2-ts-relayer)).

Proven live: a local 3-validator gno testnet ⇄ Sepolia, GNOT there and back, several times (latest run
recorded on video, see [Demo](#demo-video)).

## Repositories

All checked out side by side under `/Volumes/Tendermint/gnolang/` (TS relayer one level up).

| Repo | Branch | Head | Pushed? |
|---|---|---|---|
| `gno` (origin gnolang/gno) | `feat/secp256k1-validators-ibc` | see PR | yes — [gnolang/gno#6375](https://github.com/gnolang/gno/pull/6375) |
| `gno-realms` (origin allinbits/gno-realms) | `feat/ethereum-light-client` | `e0b12e6` | yes (no PR yet) |
| `gno-eth-ibc` (origin [allinbits/gno-eth-ibc](https://github.com/allinbits/gno-eth-ibc)) | `main` | see `git log` | yes |
| `ibc-v2-ts-relayer` (origin allinbits) | `feat/ethereum-clients` | `39cbf6f` | yes — PR #40 |
| `gno` | `fix-realm-param-key-colons` (clockworkgr) | — | yes — gnolang/gno#6358 |

### gno — `feat/secp256k1-validators-ibc` (on top of master `3a4e83048`)

| Commit | What |
|---|---|
| `9786127c4` feat(tm2) | secp256k1 validator consensus keys allowed by params (both types); `KeyType`, `GenerateFileKeyOfType`; `gnoland secrets init -validator-key-type` (empty = default); **new keys default to secp256k1**. `TestReactorBasicSecp256k1`. ADR `tm2/adr/pr6375_secp256k1_validator_keys.md` (note `pr5949_remove_secp256k1_validators.md` is the earlier opposite decision). |
| `d6013ecc3` feat(gnovm) | stdlib `crypto/bls12381.FastAggregateVerify` native (gas row Base 2,024,000 / Slope 1,962,000, draft). ADR `gnovm/adr/pr6375_bls12381_native.md`. Builds on the BLS idea of gnolang/gno#5583. |
| `2e1ca74b4` fix(gnovm,vm) | colons allowed in realm param names (`realmFromKey` splits on the first colon). Needed because IBC packet keys contain `:`. ADR `pr6358_param_key_colons.md`. Also proposed alone as **gnolang/gno#6358** (open, lint fixed, needs a maintainer review). |
| `038e4c5ed` chore | `strings.Cut` in `realmFromKey` (go fix lint) |
| `e75f6a699` feat(gnovm) | `bls12381.FastAggregateVerifyExcluding(aggregate, excluded, msg, sig)`: verify against a committee's aggregate key minus non-signers (gas Base 2,116,000 / Slope 1,962,000 per excluded key). App-hash test pin bumped to `9c883b97…dd16`. |

`gnoland start --lazy` and the integration txtar (valopers) were adjusted for the new default key type.

### gno-realms — `feat/ethereum-light-client`

`go.mod`/`go.sum` carry a `replace` to `../gno`, **deliberately uncommitted** (tests need the natives above).

| Package | What |
|---|---|
| `p/aib/ibc/lightclient/extproof/v0` | `extproof.Proof{Data any}` + `Verifier` interface: non-ICS23 proofs travel in the frozen IBC messages' `Ext any` field; core impl routes them. |
| `p/aib/ibc/lightclient/ethereum/v0` | the Ethereum light client. Client type `ethereum`, client ids `ethereum-N`, heights = beacon slots (revision 0). State: `ClientState` (chain params, forks, router address + commitments slot), `ConsensusState` (slot, execution state root, timestamp, current/next sync committee *summaries* = pubkeys SSZ root + aggregate pubkey). Updates carry only **non-signers** with Merkle branches to the pubkeys root and are verified with `FastAggregateVerifyExcluding`. Accepts next-committee-only updates (spec `apply_light_client_update`). Gloas: different generalized indices (finality 735, next committee 2946, exec block hash 2856 vs Electra 169/87/25) and the relayer supplies the RLP execution header, checked against the committed block hash. Wire decoders: `DecodeHeader`, `DecodeMisbehaviour`, `DecodeMembershipProof`. |
| `p/aib/encoding/wire/v0` | originally from github.com/clockworkgr/gno-upgradeable (`p/clockwork/wire/v0`): Uint = 8-byte BE, Uvarint = LEB128, Str/Blob = uvarint length + bytes, Bool/Byte = 1 byte. |
| `r/aib/ibc/ethrelay` | MsgCall entry points taking `[]byte` (base64 on the wire, decoded natively): `UpdateClient(clientID, header)`, `SubmitMisbehaviour`, `RecvPacket(msg)`, `Acknowledgement(msg)`, `Timeout(msg)`. Avoids MsgRun's ~1250 gas/byte preprocessing. |
| `p/aib/ibc/ics20/abi/v0` + transfer realm | ICS20 payloads ABI-encoded (`application/x-solidity-abi`) to/from `ethereum-*` clients. |
| `r/aib/ibc/core` render | `clients/{id}` renders an Ethereum client's full state (uint64s as strings), `clients/{id}/consensus_states/0/{slot}` its consensus state incl. `next_sync_committee_known` — the TS relayer reads these. |

ADR: `docs/adrs/0003-ethereum-light-client.md`. Tests: fixtures converted from eureka's (`cmd/gen-eth-fixtures`),
a live-Sepolia snapshot test (`zz_snapshot_sepolia_test.gno`, generated by `relayer/cmd/eth-snapshot` here),
regression filetest z15b (seq 58), z15a renders.

### gno-eth-ibc (this repo)

- `contracts/` (Foundry, **run only via Docker**: `make test`, `make build`): `GnoLightClient.sol` (tm2
  commits: sha256 header Merkle root, CanonicalVote sign bytes, secp256k1 via ecrecover, low-S; validator
  sets cached by hash; packed 81-byte signatures; minimal signer set; ICS23 B+tree + simple multistore
  proofs; misbehaviour freezes), `GnoVoucher.sol` (see [decimals](#token-decimals)),
  `script/DeployGnoIBC.s.sol`, `script/RegisterGnoDenom.s.sol`, `script/GnoDenoms.sol`. 88 tests.
  eureka is a submodule at `solidity-v3.0.2`.
- `relayer/` (Go): packages `beacon`, `eth`, `ethgno` (wire encoders, Gno renderers, execution headers),
  `gno`, `gnoibc` (tm2 → GnoLightClient encoding), `relay` (`gno_to_eth.go`, `eth_to_gno.go`,
  `gno_acks.go`). CLI `relayer/cmd/relayer`: `trust`, `gno-create-eth-client` (placeholder, for anvil),
  `gno-create-eth-client-live`, `gno-register-counterparty`, `gno-update-eth-client`, `relay`,
  `relay-eth`, `relay-gno-acks`, `eth-send-transfer`, `erc20-balance`. Also `cmd/eth-snapshot`,
  `cmd/ts-vectors` (wire vectors for the TS relayer).
- `fixtures/`: `cmd/genfixtures` (Solidity fixtures from real tm2 code; `-ts-out` writes the TS relayer's
  gnoibc vectors).
- `testnet/up.sh` / `down.sh`: N=3 secp256k1 validators, examples + gno-realms staged into genesis (one
  tree, tests/filetests stripped to avoid import cycles). `DATA` and `PORT_OFFSET` run several testnets side
  by side. `down.sh` keeps state; `up.sh -reset` wipes.
- `scripts/e2e-local.sh` (`make e2e-local`: testnet + anvil, gno → EVM transfers) and
  `scripts/sepolia.sh` (`make sepolia-setup | sepolia-to-eth | sepolia-to-gno`).

### ibc-v2-ts-relayer — `feat/ethereum-clients`, PR allinbits/ibc-v2-ts-relayer#40 (open)

`ClientType.Ethereum`, `EthereumIbcClient` (viem 2.57.1); Ethereum as a source (`source.ts`, `beacon.ts`,
`execution.ts`, `wire.ts`), as a host of gno clients (`host.ts`, `gnoibc.ts`, artifacts from
`pnpm gen:eth-artifacts`), gno hosting Ethereum clients (`src/clients/gno/ethereum.ts` + `IbcClient.ts`:
create/register via MsgRun, everything else via `ethrelay` MsgCall), `add-ethereum-chain` CLI, chain configs
in storage. Byte-equality tests against the Go encoders. `pnpm test:eth-host:e2e` runs against
`make e2e-local`'s chains, using only the TS clients. Verified live against Sepolia: create + update the gno
Ethereum client, and receive a Sepolia packet on gno.

## How to run

```sh
make test            # Solidity (Docker)
make relayer-test    # Go
make e2e-local       # local testnet + anvil
make sepolia-setup   # fresh testnet + deploy on Sepolia + gno's Ethereum client  (~12 min)
make sepolia-to-eth  # 1 GNOT gno -> Sepolia, ack back                              (~14 min)
make sepolia-to-gno  # vouchers Sepolia -> gno, ack back                            (~17 min)
make e2e-down        # stop anvil + default testnet
```

`gno-realms` tests: `go run github.com/gnolang/gno/gnovm/cmd/gno test ./gno.land/...` from gno-realms
(needs the go.mod replace). gno: `go test ./gnovm/stdlibs/crypto/bls12381/...`, integration txtars.

Everything is **down** now (both local testnets stopped with state kept in `testnet/.data` and
`testnet/.data-perf`; anvil container removed). The Sepolia `testnet/.data` chain is the one the current
Sepolia deployment trusts: restarting it with `testnet/up.sh` (no `-reset`) resumes it, but GnoLightClient
will only accept it within its trusting period; `make sepolia-setup` starts over cleanly.

## Sepolia

- **Account / key**: `.env` (gitignored, 0600) holds `DEPLOYER_ADDRESS=0xE6F1390EF5a96Bb319Cad61B1a448DDc857a0b88`,
  `DEPLOYER_PRIVATE_KEY`, `ETH_PRIVATE_KEY` (same key). ~0.0723 Sepolia ETH left. The previous key
  (`0xcef93Bc2…6135`, swept to 0) is in `.env.bak-20261016`. Never print or commit either.
- **Current deployment** (`contracts/deployments/sepolia.json`, gitignored): router
  `0x24180a7A2d646A2cEBd8888F7682B6BfB83aaC6B`, ICS20 `0x9a49d23fdCA04A06B7Dd59b503e91fa58E7170aa`,
  GnoLightClient `0x8638F4d152001731941450856F87a4cDDEf59ed7` (`client-0` ↔ gno `ethereum-1`), GNOT voucher
  `0xa076F366a57D07af66a1027bcC7B2546d1CC2770`, AccessManager `0x132f9907B634cA34DbA00e41c55bedd632B07976`.
  Older deployments (2026-10-15, and three aborted ones today) are orphaned.
- **Network facts that cost a failed run each:**
  - Sepolia runs **Gloas (ePBS) + Glamsterdam**. Light-client headers carry only `execution_block_hash`; the
    relayer fetches and RLP-encodes the execution header (with `blockAccessListHash`, `slotNumber`).
    Contract creation costs ~5× Cancun; deployment ≈120M gas. Mainnet is still Fulu/Osaka.
  - forge on Sepolia needs `--skip-simulation --gas-estimate-multiplier 130` (local simulation
    underestimates).
  - Load-balanced RPCs report **stale nonces right after a receipt**: forge aborts (`provider nonce (N) is
    still behind expected nonce (N+1)`). `sepolia.sh` resumes with `forge script --resume`, writes a resumed
    run's (wrong, re-simulated) addresses to `deployments/.sepolia-resumed.json`, and checks the router has
    code. They also cause stale reads after writes: read at the receipt's block.
  - `eth_getProof` at the **finalized** block (64–96 behind head): only `https://rpc.sepolia.ethpandaops.io`
    worked among public RPCs (publicnode, 1rpc, tenderly refuse: "maximum proof window").
  - Beacon API: `https://lodestar-sepolia.chainsafe.io`; bootstraps only for recent finalized checkpoints.
  - Gas price was 16–36 wei: the whole demo cost 0.00003 ETH.

## Gas (measured)

| gno (gas units; 1 ugnot / 1000 gas on mainnet pricing) | |
|---|---|
| create Ethereum client (MsgRun) | 46M |
| Ethereum client update, finality | ~40M |
| update revealing next committee / crossing a period | 36.8M / 50–54M |
| `RecvPacket` from Ethereum (MPT storage proof) | 94M |
| `Acknowledgement` from Ethereum | 63M |
| ICS20 `Transfer` to Ethereum | 70M |
| storage deposit per update | ~6.1 KB (consensus states are never pruned yet) |

| Sepolia (3 validators) | |
|---|---|
| `updateClient`, set cached / first sight (caches set) | 463k / 928k |
| `recvPacket` steady / first on a client (creates escrow) | ~549k / 1.87M |
| `sendTransfer` | 348k |
| `ackPacket` | 398k |

Estimate for **15 validators on mainnet** pricing: update ~245k, validator-set change ~730k, recv ~360k,
ack ~200k (see `contracts/README.md` for the scaling table; `make gas`).

Gas history worth remembering: a finality update was 641M gas with MsgRun + hex decoding in the VM,
259M with `[]byte("…")` literals, 40M with non-signers + aggregate key + MsgCall/wire.

## Token decimals

ICS20 carries raw base units; decimals are display metadata.

- **gno-native denoms on Ethereum**: eureka's auto-deployed `IBCERC20` reports 18 decimals and has no
  setter (eureka removed `setMetadata` in PR #554; upstream's supported path is
  `ICS20Transfer.setCustomERC20`). So `GnoVoucher` (fixed name/symbol/decimals, mint/burn only by ICS20) is
  deployed and registered **before the first transfer**: ugnot as "Gno.land"/GNOT/6 by `DeployGnoIBC`,
  others with `RegisterGnoDenom.s.sol`. Once a denom has a token, `setCustomERC20` refuses it.
- **Ethereum tokens on gno — OPEN**: gno vouchers are GRC20s (`p/nt/grc20/v0`), int64 throughout, and the
  transfer app parses amounts with `AmountInt64`. Gnoswap and grc20reg are int64 too. So an 18-decimal ERC20
  is capped at ~9.22 tokens (per transfer and total supply); excess gets an error ack and refund. Proposed
  (not built): a per-token **6-decimal wrapper** on Ethereum (factory; `wrap` takes only whole multiples of
  10^(d−6), refunds ETH dust; `unwrap`; `wrapAndSend` helper), no ICS20 changes, tokens ≤ ~9 decimals
  (USDC, WBTC) bridged directly. Alternatives considered: forking ICS20 to scale (touches audited code),
  256-bit vouchers on gno (incompatible with every GRC20 consumer), accepting the cap.

## Open items

- **Decide and build the Ethereum → gno decimals solution** (above).
- **Relayer bug**: `relay-gno-acks` re-sent an ack `relay-eth` had just delivered (stale read); the router
  no-oped it (wasted ~398k gas). Read the commitment at the latest receipt's block before sending.
- **Prune/slim consensus states** of the gno Ethereum client (each update stores ~6 KB, deposit never
  refunded).
- `ethrelay.CreateClient` / `RegisterCounterparty` taking wire bytes, to drop the last MsgRun (user said not
  needed for now).
- TS relayer: `findConflictingHeader` for GnoLightClient unsupported; `getConsensusStatesAfter` scans
  `eth_getLogs` from block 0 (public RPCs may refuse); Ethereum-side `maxClockDrift` (20 s) vs block time lag.
- Publish: gno is PR gnolang/gno#6375 (with the full ADR `gno.land/adr/pr6375_ibc_ethereum.md`); gno-realms
  `feat/ethereum-light-client` is pushed but has no PR yet; gno-eth-ibc is public at allinbits/gno-eth-ibc.
  gnolang/gno#6358 needs a reviewer. `GnoLightClient` artifacts in the TS relayer record gno-eth-ibc commit
  `ca63b51`.
- BLS native gas rows are drafts; validate before proposing upstream.
- Mainnet: Gloas is unscheduled there; the client supports Electra/Fulu paths and was tested with fixtures.

## Demo video

`demo/` (excluded via `.git/info/exclude`): `demo/gno-sepolia-ibc.mp4` (7:04, 1080p) — setup, 1 GNOT to
Sepolia and back, terminal + Etherscan + gnoscan (custom network via a local tx-indexer). `demo/STEPS.md`
has the timeline, every tx with links and gas, balances, and what went wrong. Recorder scripts in
`demo/recorder/` (pty → asciicast with key redaction, time compression, xterm.js replay, Playwright pages,
ffmpeg assembly). Note: gnoscan shows balances/validators wrongly for this chain version, so those are
shown as live node queries.

## Related

The full design is the ADR in gnolang/gno#6375 (`gno.land/adr/pr6375_ibc_ethereum.md`).
`docs/bridges-review.md`: review of gnolang/bridges (the Hyperlane-based Solana bridge and its Ethereum draft) and the plan to add its controls to this IBC stack.

## Conventions for this work

- No AI attribution anywhere (commits, PRs, comments) — the user's global instruction.
- Commit messages: conventional, describing the change.
- Never force push; never `--no-verify`; secrets only in `.env`.
- Foundry only through Docker (`ghcr.io/foundry-rs/foundry:v1.7.1`).
