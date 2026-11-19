# gno.land ⇄ Arc

[Arc](https://github.com/circlefin/arc-node) is Circle's EVM L1, with
Malachite (Tendermint BFT) consensus, Reth execution and USDC as gas. This
branch (`feat/arc-ibc`) runs the gno.land ⇄ Ethereum stack against Arc. A
gno.land chain can run an Arc route beside its Ethereum route: ibcgov governs
one route per counterparty chain, each with its own governance channel and
IBCAdmin (gno-realms ADR 0007, allinbits/gno-realms#100).

| Side | What runs | Changed for Arc |
|---|---|---|
| Arc | solidity-ibc-eureka's ICS26 router, the ICS20 fork, `GnoLightClient.sol`, IBCAdmin | nothing in `contracts/src`; `DeployGnoIBC.s.sol` knows Arc's chain ids |
| gno.land | the Arc light client, `gno.land/p/aib/ibc/lightclient/arc/v0` (allinbits/gno-realms#98, `feat/arc-light-client`) | new client; core, transfer and ibcgov treat `arc` as a router client like `ethereum` |
| relayer | `relayer/arc`, `relay/arc_to_gno.go`, `cmd/relayer` `gno-create-arc-client`, `gno-update-arc-client`, `relay-arc`; the TypeScript relayer (ibc-v2-ts-relayer) also relays Arc | gno → Arc uses the EVM path unchanged (`relay`, `relay-gno-acks`) |

The design of the gno.land client, with what was verified in Arc's source and
on the testnet, is gno-realms
[`docs/adrs/0008-arc-light-client.md`](https://github.com/allinbits/gno-realms/blob/feat/arc-light-client/docs/adrs/0008-arc-light-client.md).
In short: an update proves a block B from its own state (the registry's
validator set, by storage proofs) and certifies it with the Malachite
commit certificate of B+1, whose Ed25519 precommits sign an SSZ vote over
the EVM block hash. Packet proofs are `eth_getProof` storage proofs, as on
Ethereum.

## Networks

| | Chain id | RPC |
|---|---|---|
| Arc mainnet | 5042 | |
| Arc testnet | 5042002 | certificates and transactions: `https://rpc.testnet.arc.io`; latest-block proofs: `https://rpc.drpc.testnet.arc.io` |
| Arc devnet | 5042001 | |

Arc's public nodes serve `eth_getProof` at the latest block only, which is
why the client is shaped the way it is (ADR 0008, "Why B and not C"). No one
public endpoint serves everything well:

- the official `rpc.testnet.arc.io` serves `arc_getCertificate`, but not
  `eth_getProof`;
- drpc serves `eth_getProof` at `latest` (not at a block number), but
  answers "Certificate not found";
- blockdaemon serves both, but sometimes returns a compressed body without a
  `Content-Encoding` header, which go-ethereum and forge cannot read.

The relayer takes the two separately (`-arc-cert-rpc`, default the official
RPC; `-arc-rpc`, default drpc); deploy with the official RPC.

## Deploying on Arc

`DeployGnoIBC.s.sol` runs as on Ethereum, with Arc's RPC:

- On an Arc chain the gno-side client id defaults to `arc-1`
  (`GNO_COUNTERPARTY_CLIENT_ID`).
- Arc mainnet (5042) gets Ethereum mainnet's guards: no `LAUNCH_ACTIVE`, the
  recovery launches enabled.
- Gas is paid in USDC: fund the deployer from Circle's testnet faucet.
- `PERMIT2`: leave unset unless Permit2 is deployed on the network.
- On test networks `LAUNCH_ACTIVE=true` works as on Sepolia; otherwise
  the route is activated by gno.land's kind 4, as on Ethereum.

Then, on gno.land (the gno-realms `feat/arc-light-client` realms deployed):

```sh
relayer gno-create-arc-client -deployment contracts/deployments/5042002.json
relayer gno-register-counterparty ...            # the router's client id, as for Ethereum
relayer relay-arc -deployment contracts/deployments/5042002.json -follow   # Arc -> gno
relayer relay -deployment contracts/deployments/5042002.json -follow       # gno -> Arc
```

## Fixtures

`relayer/cmd/arc-fixtures` records a client creation and an update from the
live testnet into gno-realms `gno.land/p/aib/ibc/lightclient/arc/testing/v0/testnet.gno`,
which the client's unit tests and the `ethrelay` filetest replay.

## Testnet

On 2026-11-03 a separate gno.land chain, `test-arc-1`, ran a route to Arc
testnet: the contracts deployed with this script, the governance launch done
over the channel bound to `arc-1` (Arc's IBCAdmin recorded gno.land's
decisions), GNOT sent gno → Arc and acknowledged, and a test ERC20 sent
Arc → gno and claimed. No Solidity change was needed, so the Foundry suite is
the Ethereum one.
