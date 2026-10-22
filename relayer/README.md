# relayer

An IBC v2 relayer between gno.land and an EVM chain running solidity-ibc-eureka v3.0.2 with
`GnoLightClient`. Today it relays gno.land → EVM; the EVM → gno.land direction plugs into the same
packages (see "Adding the other direction").

## Layout

| package | role |
|---|---|
| `ibc` | chain-agnostic IBC v2 types: `Packet`, `Payload`, `Height`, ICS24 paths, packet / ack commitments, decoding of the core realm's `encoded_packet_hex` |
| `gnoibc` | tm2 → ABI encoding of GnoLightClient messages (headers, commits, validator sets, ICS23 proofs); shared with `../fixtures` |
| `gno` | gno.land side: RPC (signed headers, validator sets, `.store/main/key` proofs with `prove=true`, block-result events), transactions through `gnoclient` (MsgCall, MsgRun), MsgRun scripts (placeholder Ethereum client, RegisterCounterparty) |
| `eth` | EVM side: go-ethereum client and `BoundContract`s for ICS26Router, ICS20Transfer, GnoLightClient and IBCERC20, with the ABIs Foundry compiled embedded from `eth/abi` (`make abis` refreshes them) |
| `relay` | the relaying logic: `GnoToEth` (update GnoLightClient, prove, `recvPacket`, check the ack commitment), the `AckRelayer` hook for acks going back to gno, and `TrustedState` for a new client |
| `cmd/relayer` | the CLI |

`relayer/ethgno` and `relayer/beacon` (beacon API client, Ethereum light-client messages rendered as
Gno literals) are written separately and plug in as an `relay.AckProofSource`.

## CLI

Secrets come from the environment only: `GNO_MNEMONIC` signs gno.land transactions,
`ETH_PRIVATE_KEY` signs EVM transactions; `ETH_RPC_URL` is the default EVM RPC.

```
relayer trust -gno-rpc URL [-height H] [-trusting-period 336h] [-max-clock-drift 30s] -out deployments/trust.json
relayer gno-create-eth-client -gno-rpc URL -evm-chain-id 31337 [-router 0x..] -out gno-client.json
relayer gno-register-counterparty -gno-rpc URL -client ethereum-1 -counterparty client-0
relayer relay -gno-rpc URL -eth-rpc URL -deployment contracts/deployments/local.json [-from H] [-to H] [-from-block B] [-follow] [-out relay.json]
relayer erc20-balance -eth-rpc URL -deployment ... -denom transfer/client-0/ugnot -owner 0x..
```

`trust` creates the client at the revision its chain id carries (`{name}-{N}` is revision N, as
gno.land's `types.ParseChainID`; anything else is 0). Proof heights then carry the revision the
deployed client's state holds, read from `getClientState`, whatever the chain id derives: an older
client keeps the revision it was created with.

The router's logs (`SendPacket`, `WriteAcknowledgement`) are scanned from the deployment's
`deployBlock` (written by `DeployGnoIBC.s.sol`; `-from-block` sets it for a record without one), in
chunks that halve when the RPC refuses the range, newest first when one event is wanted.

## gno.land → EVM

For the `send_packet` events of the core realm (`gno.land/r/aib/ibc/core`) on the gno-side client:

1. pick the proof height: the state after block `q` (the latest block whose successor is committed),
   because header `q+1` carries the AppHash of that state;
2. update GnoLightClient to `q+1` from its latest consensus state `T` through
   `ICS26Router.updateClient`: header and commit of `q+1` with the fewest signatures that clear 2/3
   (highest power first; across a validator set change, first enough of the trusted set's signers to
   clear the trust level), its validator set unless the client has it cached
   (`isValidatorSetCached`), and the validators of `T+1` only if they differ from those of `q+1` and
   are not cached;
3. query `"/pv/vm:gno.land/r/aib/ibc/core:" || client || 0x01 || seq_be` in the `main` store at
   height `q` with `prove=true`, check the value is the packet's commitment, encode the two ICS23 ops;
4. `ICS26Router.recvPacket(packet, proof, {0, q+1})`, then read the `WriteAcknowledgement` event and
   check `getCommitment(keccak256(client || 0x03 || seq))` equals the ack commitment;
5. hand the ack to the `AckRelayer`.

## Acks back to gno.land

`relay.GnoAckSubmitter` submits `core.Acknowledgement(cross(cur), types.MsgAcknowledgement{...})` in a
MsgRun with the proof in `Ext: extproof.Proof{Data: <ethereum.MembershipProof>}`. The proof
expression comes from an `AckProofSource`, which must first bring gno's Ethereum client to a finalized
slot covering the EVM block; that needs a beacon chain. On anvil there is none, so the CLI uses
`relay.SkipAcks`, which only logs.

## Adding the other direction

EVM → gno.land packets reuse `eth` (watch `SendPacket` logs), `ibc` (packet types and paths), `gno`
(`Run` with a rendered `core.RecvPacket` script, as `AcknowledgementScript` does for acks) and the
same `AckProofSource`-style proof rendering; it goes in its own `relay` file next to `gno_to_eth.go`.
