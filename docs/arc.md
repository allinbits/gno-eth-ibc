# gno.land ⇄ Arc

[Arc](https://github.com/circlefin/arc-node) is Circle's EVM L1, with
Malachite (Tendermint BFT) consensus, Reth execution and USDC as gas. This
branch (`feat/arc-ibc`) runs the gno.land ⇄ Ethereum stack against Arc.

| Side | What runs | Changed for Arc |
|---|---|---|
| Arc | solidity-ibc-eureka's ICS26 router, the ICS20 fork, `GnoLightClient.sol`, IBCAdmin | nothing in `contracts/src`; `DeployGnoIBC.s.sol` knows Arc's chain ids |
| gno.land | the Arc light client, `gno.land/p/aib/ibc/lightclient/arc/v0` in allinbits/gno-realms `feat/arc-ibc` | new client; core, transfer and ibcgov treat `arc` as a router client like `ethereum` |
| relayer | `relayer/arc`, `relay/arc_to_gno.go`, `cmd/relayer` `gno-create-arc-client`, `gno-update-arc-client`, `relay-arc` | gno → Arc uses the EVM path unchanged (`relay`, `relay-gno-acks`) |

The design of the gno.land client, with what was verified in Arc's source and
on the testnet, is gno-realms
[`docs/adrs/0005-arc-light-client.md`](https://github.com/allinbits/gno-realms/blob/feat/arc-ibc/docs/adrs/0005-arc-light-client.md).
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
why the client is shaped the way it is (ADR 0005, "Why B and not C"). No one
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
- On the testnet use `LAUNCH_ACTIVE=true`: gno.land's governance channel
  binds Ethereum's IBCAdmin only (ADR 0005, "Not yet done"), so the Arc
  route cannot be activated by a gno.land decision yet.

Then, on gno.land (the gno-realms `feat/arc-ibc` realms deployed):

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

## Not done

- A packet round trip on the testnet: no ICS26 router is deployed on Arc
  yet (needs a funded deployer).
- The Arc governance channel (IBCAdmin on Arc receiving gno.land decisions).
- A Solidity-side change: none was needed, so the Foundry suite is the
  Ethereum one.
