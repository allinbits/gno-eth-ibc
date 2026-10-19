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
  r/aib/ibc/apps/transfer (ICS20)                     ICS20Transfer (ICS20, GnoVoucher vouchers)
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
launch limits derive). Relaying stays public: leave `RELAYER_ADDRESS` unset
(a restricted deployment also needs `ALLOW_RESTRICTED_RELAYING=true`, for
testing only). See [docs/controls.md](docs/controls.md#deployment) for the
deployment and its checks). Optional settings:

- `GNOT_MAX_PER_MESSAGE`, `GNOT_DAY_CAP`, `GNOT_REFUND_CAP`: override the ugnot
  launch limits derived from `EXPECTED_LOCK`; zero (the default) keeps the
  derived value, and an override may only lower it.
- `QUARANTINE_SECONDS`: the launch quarantine (default 7 days; later changes by
  kind 11 are capped at 365 days).
- `RECOVERY_DELAY` (0, the default, disables the emergency recovery; otherwise
  at least 30 days), `RECOVERY_THRESHOLD` and `RECOVERY_CANCEL_THRESHOLD`
  (default 3; 3 or 4 when enabled, cancellation at most approval),
  `RECOVERY_SILENCE` (default 30 days) and
  `RECOVERY_HOLD_PERIOD` (default 14 days), zero disabling either criterion.
  The recovery is fixed at deployment: enabling it is a pre-deployment
  decision, with no later governed enablement.
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
