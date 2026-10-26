# gno-eth-ibc

IBC v2 between a gno.land chain and Ethereum: a gno.land light client in
Solidity, the deployment of the solidity-ibc-eureka router and ICS20 app with
it, a relayer for both directions, and scripts for a local testnet and Sepolia.

The other halves live in two branches:

| Repo | Branch | What |
|---|---|---|
| gnolang/gno | `feat/secp256k1-validators-ibc` | secp256k1 validator keys; `crypto/bls12381` natives; colons in realm param names |
| allinbits/gno-realms | `feat/ethereum-light-client` | Ethereum light client (`p/aib/ibc/lightclient/ethereum`), `r/aib/ibc/ethrelay`, ABI ICS20 payloads |

## How it fits

```
gno.land (3 secp256k1 validators)                    Ethereum (Sepolia)
  r/aib/ibc/core ── client ethereum-1  <──────────>  ICS26Router ── client-0 = GnoLightClient
  r/aib/ibc/apps/transfer (ICS20)                     GnoICS20Transfer (ICS20 fork + controls, GnoVoucher)
  p/aib/ibc/lightclient/ethereum                      contracts/src/GnoLightClient.sol
      sync committee + BLS (gno native)                   tm2 commits: sha256 + ecrecover
      MPT storage proofs                                  ICS23 B+tree + multistore proofs
```

- **gno → Ethereum**: `GnoLightClient` verifies tm2 commits signed with
  secp256k1 (`ecrecover`), caches validator sets by hash, and proves the core
  realm's packet state (params under `/pv/vm:gno.land/r/aib/ibc/core:` in the
  `main` B+tree store) with ICS23.
- **Ethereum → gno**: the gno client follows the Altair sync protocol through
  Gloas. Updates carry no committee keys: the signature is checked against the
  committee's aggregate key minus the non-signers
  (`bls12381.FastAggregateVerifyExcluding`). Storage is proven with
  `eth_getProof` at finalized blocks. Messages go through `MsgCall` to
  `r/aib/ibc/ethrelay` in the `p/aib/encoding/wire/v0` format.

## Run it

```sh
make test          # Solidity tests (Foundry in Docker)
make relayer-test  # Go tests
make e2e-local     # local testnet + anvil: gno -> EVM transfers, end to end
```

Against Sepolia (needs a funded key in `.env`: `DEPLOYER_PRIVATE_KEY`,
`ETH_PRIVATE_KEY`, `DEPLOYER_ADDRESS`; and, off a local chain, the deployment
settings `DeployGnoIBC` requires: `GUARDIANS` (4 comma-separated addresses),
`WATCH_KEYS` (2) and `EXPECTED_LOCK` (the expected ugnot lock in base units, from which the
launch limits derive). Relaying is public: `scripts/sepolia.sh` forwards
neither `RELAYER_ADDRESS` nor `ALLOW_RESTRICTED_RELAYING`, so the Sepolia
setup always deploys public relaying whatever `.env` says; a restricted
deployment (testing only) is made by running `DeployGnoIBC` directly with
`RELAYER_ADDRESS` and `ALLOW_RESTRICTED_RELAYING=true`. See [docs/controls.md](docs/controls.md#deployment) for the
deployment and its checks). Optional settings:

- The ugnot route launches **inactive** (zero limits): nothing moves until
  gno.land, once IBCAdmin has recorded its first decision, activates it with a
  kind 4 carrying the deployment file's `activationKind4Params`.
  `GNOT_MAX_PER_MESSAGE`, `GNOT_DAY_CAP`, `GNOT_REFUND_CAP` lower the activation
  limits derived from `EXPECTED_LOCK` (zero, the default, keeps the derived
  value). `LAUNCH_ACTIVE=true` installs them at launch instead: test networks
  only (refused on mainnet); `make e2e-local` and the Sepolia setup use it.
- `QUARANTINE_SECONDS`: the launch quarantine (default 7 days, at most 365
  days: the deployment sets it through `setQuarantine`, whose ceiling applies
  to it as to every later kind 11 change).
- `RECOVERY_DELAY` (default 30 days: the emergency recovery launches
  enabled; at least 30 days; 0 deploys it disabled, test networks only),
  `RECOVERY_THRESHOLD` and `RECOVERY_CANCEL_THRESHOLD` (default 3; 3 or 4,
  cancellation at most approval), `RECOVERY_SILENCE` (default 30 days) and
  `RECOVERY_HOLD_PERIOD` (default 14 days), zero disabling either criterion.
  The settings are fixed at deployment. gno.land's governance can later
  disable the recovery for good (kind 14, after 7 days); nothing re-enables
  it. With it disabled, a channel loss with no repair already recorded can
  strand the escrow's backing for good (see docs/controls.md).
- `PERMIT2`: the chain's Permit2 contract, fixed at deployment; unset, only
  allowance-based sends work (`sendTransferWithPermit2` is unavailable).

```sh
make sepolia-setup   # fresh testnet, deploy on Sepolia, create gno's Ethereum client
make sepolia-to-eth  # ugnot gno -> Sepolia, ack back to gno (waits for Sepolia finality)
make sepolia-to-gno  # vouchers Sepolia -> gno, ack back to Sepolia
```

Relaying to gno proves storage at the finalized block (64 to 96 blocks behind
head). Most public Sepolia RPCs cannot (`distance to target block exceeds
maximum proof window`); `https://rpc.sepolia.ethpandaops.io` can. Set
`PROOF_RPC` to your own archive node otherwise.

## Gas

| Operation | Gas |
|---|---|
| gno: Ethereum client update (512-member committee, live Sepolia) | ~40M |
| gno: next sync committee update | ~37M |
| gno: acknowledgement with a Sepolia storage proof | ~63M |
| gno: ICS20 transfer to Ethereum | ~70M |
| Sepolia: `GnoLightClient` update, 3 validators, set cached | ~463k |
| anvil (Cancun pricing): same update | ~196k |
| anvil: `recvPacket` ICS20, steady state / first of a denom | ~360k / ~880k |

Sepolia runs Glamsterdam, whose repricing makes storage and contract creation
much costlier than Foundry's and anvil's Cancun rules: deployment took 120M
gas there. See `contracts/README.md` for the full scaling table by validator
count.
