# Ethereum controls (ADR pr6375 E5–E9, E11, E12)

The Ethereum side of the safety and governance controls of the gno.land ⇄ Ethereum IBC ADR
(`gno.land/adr/pr6375_ibc_ethereum.md` in the gno repository, §4.4, §5.4, §6–§7, §9). This page lists what is
built, where each rule lives, and where the implementation departs from the ADR.

## Contracts

| Contract | File | What it is |
|---|---|---|
| `GnoICS20Transfer` | `contracts/src/GnoICS20Transfer.sol` | Minimal fork of eureka v3.0.2 `ICS20Transfer` (MIT); every change is marked `GNO:`. Installed by the ICS20 proxy's own UUPS upgrade. Hot path of the controls: receive checks and limits, send checks and send records, refunds (paid, metered, queued, held). |
| `GnoICS20Controls` | `contracts/src/transfer/GnoICS20Controls.sol` | The controls' governance setters, guardian flags, `claim` and views. Runs only by delegatecall from `GnoICS20Transfer`'s `fallback` (EIP-170 keeps the two apart); its address is an immutable of the fork's implementation. |
| `GnoTransferStorage` | `contracts/src/transfer/GnoTransferStorage.sol` | The fork's ERC-7201 layout (`gno.storage.GnoICS20Transfer`) and the route-key helpers both halves use. |
| `IBCAdmin` | `contracts/src/admin/IBCAdmin.sol` | Permanent, immutable IBC app on port `ibcgov`: the §5.4 delivery protocol, the decision ledger, flags on itself, execution scheduling, recovery entry points, `finishSetup`. Holds `ADMIN_ROLE`. |
| `IBCAdminExec` | `contracts/src/admin/IBCAdminExec.sol` | The executor: every kind at recording and at execution, the emergency recovery. Delegatecalled at a pinned code hash; replaced only by kind 9. |
| `IBCAdminStorage` | `contracts/src/admin/IBCAdminStorage.sol` | IBCAdmin's ERC-7201 layout (`gno.storage.IBCAdmin`), constants, tombstones, hold history. |
| `IBCAdminSetupCheck` | `contracts/src/admin/IBCAdminSetupCheck.sol` | `finishSetup`'s numbered check list (a view contract the executor calls). |
| `FrozenLightClient` | `contracts/src/admin/FrozenLightClient.sol` | What a retired client id is `migrateClient`ed to: proves nothing, reads as frozen. |
| `Guardians` | `contracts/src/lib/Guardians.sol` | Ported from gnolang/bridges `lib/Guardians.sol` (GNO Network GPL): 4 guardian seats, 2 watch keys, flags, holds, 24 h dip, replacement rules. |
| `LeakyBucket` | `contracts/src/lib/LeakyBucket.sol` | Ported from gnolang/bridges `PausableGate._charge/_level` (GNO Network GPL): the day-cap bucket of receive limits and the refund meter. |
| `GnoLightClient` | `contracts/src/GnoLightClient.sol` | Gains the live epoch and `quarantineEnd(duration)` (E9), `isFrozen`, `isExpired`. |

Files ported from gnolang/bridges carry `SPDX-License-Identifier: LicenseRef-GNO-Network-GPL` and a header naming
their source path; the license text is `contracts/licenses/GNO-Network-GPL.md`. Note that its copyleft and
attribution terms extend to works that use those files.

## Storage

- **eureka's ICS20Transfer namespace** (`ibc.storage.ICS20Transfer`) is unchanged. `_escrows` and the denom paths
  of the custom-ERC20 registry are keyed by **route key**, which equals the client id until a route is migrated, so
  a deployed proxy upgrades in place (`test/controls/UpgradeCompat.t.sol`).
- **`gno.storage.GnoICS20Transfer`** (`GnoTransferStorage.Layout`): guardian keys (IBCAdmin's copy), `routeOf`
  (client id → route key), `currentOf` (route key → current client id), `retired`, per route: pause flags, refunds
  flags, quarantine seconds, recovery block; per (route, token): limits, receive bucket, refund bucket, refund queue;
  per (client id, sequence): the send record.
- **`gno.storage.IBCAdmin`** (`IBCAdminStorage.Layout`): epoch, last seq, epoch client, last record time, conflict
  flag, executor and its code hash, decisions and tombstones keyed by epoch, guardian keys and flags, hold history,
  recovery state, `setupDone`.

## Roles (AccessManager)

| Function | Role | Holder after the setup |
|---|---|---|
| everything governed: router `addIBCApp(string,…)`, `addClient(string,…)`, `migrateClient`, `upgradeToAndCall`; transfer `setCustomERC20`, `upgradeToAndCall`, beacons, every control setter (`initializeGno`, `setGuardianKeys`, `setLimits`, `setQuarantine`, `unpauseRoute`, `setRecoveryBlock`, `migrateRoute`) | `ADMIN_ROLE` | `IBCAdmin` only |
| `recvPacket`, `ackPacket`, `timeoutPacket`, `updateClient` | `PUBLIC_ROLE` (or `RELAYER_ROLE` if `RELAYER_ADDRESS` is set) | anyone / kind 8 |
| transfer `pause` / `unpause` | `PAUSER_ROLE` / `UNPAUSER_ROLE` | nobody (ADR §7.3) |
| `sendTransferWithSender` | `DELEGATE_SENDER_ROLE` | nobody |

The deployer never holds `ID_CUSTOMIZER_ROLE` or `ERC20_CUSTOMIZER_ROLE` (those functions are `ADMIN_ROLE`'s) and
renounces `ADMIN_ROLE` at the end of `DeployGnoIBC`, which then runs `IBCAdmin.finishSetup()`.

## The governance wire format (for `ibcgov`)

- Payload: `sourcePort = "gov"`, `destPort = "ibcgov"`, `version = "ibcgov-1"`, `encoding = "application/x-ibcgov"`.
- Envelope: `version u8 (1) ‖ epoch u32 ‖ seq u64 ‖ kind u8 ‖ params`, big-endian, at most **1024** bytes;
  `params = abi.encode(field1, field2, …)` of the kind's tuple (no outer offset).
- App ack: `epoch u32 ‖ seq u64 ‖ status u8 ‖ redispatch u8` (14 bytes); status 1 recorded, 2 buffered,
  3 duplicate, 4 conflict, 5 spent. A cancel beyond the window is acknowledged `status 2, redispatch 1`.
- Every refusal is an error acknowledgement (the router's universal error ack; the custom error is only in the
  router's `IBCAppRecvPacketCallbackError` event): wrong port/version/encoding/client, undecodable envelope, other
  epoch (`StaleEpoch`), beyond the window (`BeyondWindow`), a decision starved of gas (`ExecutionStarved`).
- Byte-exact vectors: `contracts/test/fixtures/gov-vectors.json`, written and checked by
  `contracts/test/controls/GovVectors.t.sol` (`WRITE_GOV_VECTORS=true` rewrites it).

## ADR rules and where they are implemented

| Rule | Where |
|---|---|
| E5 receive limits per (route, token): max per message + leaky-bucket day cap, in `onRecvPacket` only, before minting or releasing | `GnoICS20Transfer._chargeReceive`; `LeakyBucket` |
| E5 refunds exempt from receive limits; `GnoVoucher.mint`/`Escrow.send` unlimited; eureka's escrow rate limit unset | refunds go through `_settleRefund`, never `_chargeReceive` |
| E6 default deny: a gno denom without a registered voucher (and limits) is refused, no IBCERC20 ever created | `onRecvPacket` (`GnoDenomNotRegistered`, `GnoLimitsNotSet`); `_getOrCreateIBCERC20` removed |
| E6 expected refusals revert with non-empty custom errors (router → error ack) | `IGnoICS20ControlsTypes` errors |
| E6 send limits for escrowed (Ethereum-native) tokens only (`sendMax`/`sendMin`, 0 = unset); returning vouchers never limited or paused | `_checkEscrowedSend`, skipped when `burned` |
| E6/§7.13 send record in every send variant after `sendPacket` returns the sequence | `_recordSend` (all three variants go through `_sendTransferFromEscrowWithSender`) |
| §7.13 ack/timeout attach outcome, local processing block and payment state | `_processed`, `_recordOutcome`, `_settleRefund` |
| §7.13 refund meter per (route, token), queue beyond it, permissionless `claim` (installments) | `_settleRefund`; `GnoICS20Controls.claim` |
| §7.13 refunds hold suspends proof-based refunds and claims, cancels nothing | route `refundFlags`; `setRefundsFlag`/`clearRefundsFlag`; checked in `_settleRefund` and `claim` |
| §7.3 a pause never blocks acks, timeouts or refunds; PAUSER_ROLE granted to nobody | `whenNotPaused` removed from the ack/timeout callbacks; deployment roles |
| E7 4 guardian + 2 watch seats, flags, holds (two guardian flags), 24 h hold end, unpause clears earlier flags, refused under a hold | `Guardians`; per route in the fork, on IBCAdmin itself |
| E7 route flags block receives and Ethereum-native sends only | `_checkReceiveRoute`, `_checkEscrowedSend` |
| E9 live-epoch quarantine, set once per transition, anchor-independent; governance not quarantined | `GnoLightClient._isLiveTransition`, `quarantineEnd`; checked by `_checkReceiveRoute`; never by IBCAdmin |
| §5.4 envelope, acks, statuses, window W = 64, drain D = 8, `drain()`, duplicates, conflicts | `IBCAdmin.onRecvPacket`, `_deliver`, `_record`, `_drain` |
| §5.4 cancels anywhere: tombstones on arrival (≤ 64 merged ranges per epoch), redispatch beyond the window | `IBCAdmin._parseCancel`, `_tombstone`; `IBCAdminStorage.addTombstone` |
| §5.4 epochs: another epoch refused, everything keyed by (epoch, seq) | `IBCAdmin.onRecvPacket`; `IBCAdminStorage.Layout` |
| §5.4 unknown kind / bad params recorded and spent | `IBCAdmin._record`; `IBCAdminExec.atRecording` |
| §5.4 kind delays: cancel / kind 4 tightening / kind 8 revoke / kind 11 lengthening at recording; unpause 24 h; others 7 d | `IBCAdminExec.atRecording`, `IBCAdmin.execute`, `_delay` |
| §6.6/§7.4 7-day kinds deferred by flags and holds; kind 3 through flags, through a hold at ≥ day 21 | `IBCAdmin.execute`, `_replacementFloor` |
| §7.4 unpause spent under a hold of its object | `IBCAdminExec._unpause` |
| kind 3 at most 2 guardian seats, never a current key; both key copies follow | `Guardians.checkReplace`; `IBCAdminExec._seats` |
| kind 4 limits, "no field loosens" rule | `IBCAdminExec._loosens` |
| kind 5 voucher registration, code-hash pinned, bound to the fork | `IBCAdminExec._voucher` |
| kind 6 add (custom id) / migrate a client, code-hash pinned | `IBCAdminExec._client` |
| kind 7 upgrades (router, transfer app, its two beacons), code-hash pinned, fixed call gas, after-checks | `IBCAdminExec._upgrade` |
| kind 8 relayer role only; never ADMIN or any role that upgrades or re-points | `IBCAdminExec.atRecording`/`run` |
| kind 9 hand-over: swap the pinned executor (same bindings), optional migration call | `IBCAdminExec._handover` |
| kind 10 / E12 route replacement: retire + freeze the old id, `migrateRoute`, next epoch over the new id | `IBCAdminExec._route`, `_replaceRoute`; `GnoICS20Controls.migrateRoute` |
| kind 11 route quarantine setting | `IBCAdminExec.atRecording`/`run`; `GnoICS20Controls.setQuarantine` |
| E12 route keys, constant-work migration, wire translation | `GnoTransferStorage.routeKey/toRouteDenom/toWireDenom`; `migrateRoute` |
| §7.12 emergency recovery, off unless enabled at deployment; guardian supermajority, eligibility, long delay, guardian-only cancel, suspends kinds 3, 6–10, blocks receives while open | `IBCAdmin.approveRecovery/cancelRecovery/executeRecovery`; `IBCAdminExec` recovery section |
| E4/E11 hand-over of every authority, deployer roles removed, check list read back | `script/DeployGnoIBC.s.sol`; `IBCAdmin.finishSetup`; `IBCAdminSetupCheck` |
| §9 launch values (ugnot max 25,000, day cap 100,000, refund cap = day cap, quarantine 7 d) | `DeployGnoIBC._params` (environment overrides) |

## Divergences from the ADR

1. **Port `ibcgov`, not `gov`, on Ethereum.** eureka v3.0.2's router refuses custom port ids shorter than four
   characters (`IBCIdentifiers.validateCustomIBCIdentifier`). IBCAdmin is registered on `ibcgov` and accepts
   packets whose `sourcePort` is `gov` (gno.land's port is unchanged). `ibcgov` must send with `destPort = "ibcgov"`.
2. **Envelope bound 1024 bytes, not 512.** A kind 6 carrying gno.land's two-element merkle prefix encodes to
   558 bytes.
3. **Client ids added by governance cannot start with `client-`** (same eureka validation; at least four
   characters). Kind 6 op 1 and the emergency recovery use custom ids such as `gnoland-2`.
4. **The router has no freeze**: the old client id of a route replacement is `migrateClient`ed to
   `FrozenLightClient`, which proves nothing.
5. **Quarantine duration is the route's (kind 11), not the client's.** The client records the time of its latest
   live transition and answers `quarantineEnd(duration)`; since transition times only grow this equals
   `max over transitions (t + duration)`. Changing the duration applies to the latest transition retroactively.
6. **Send records hold the router's packet commitment, not the packet bytes.** The commitment binds the full packet
   (timeout and payload); the packet itself is in the router's `SendPacket` event and is authenticated against the
   record at reconciliation. Storing the payload would roughly double a send's gas. A packet sent before the
   upgrade gets a record (without commitment) from its ack or timeout callback.
7. **Refund hold and pause flags are per route; IBCAdmin's flags are per object**, as the kind 2 table has it
   (object 1 = a route, object 2 = IBCAdmin). Guardian keys are global: IBCAdmin keeps them and pushes a copy to the
   transfer app on every kind 3; a flag stands only while the key that set it still holds the seat.
8. **Kind 2 on a route clears both its pause flags and its refunds flags** set before the decision ("lifting it
   follows the ordinary flag rules"); it is spent only under a hold of the pause flags.
9. **A cancel only withdraws numbers below its own** (its ranges are clamped to `seq − 1`), so a forged or
   misnumbered cancel cannot kill later decisions.
10. **Status of a cancel beyond the window**: the table has no status for "tombstones applied, not held"; the ack is
    `status 2 (buffered), redispatch 1`. `ibcgov` must re-send on `redispatch = 1` whatever the status.
11. **Every delivery also drains** (at most 8) besides `drain()`, so a run stopped by the bound moves on.
12. **Kind 10 is also suspended while an emergency recovery is open** (the ADR lists kinds 3 and 6–9).
13. **The emergency recovery's thresholds**: approvals are per guardian seat (one proposal per seat), opening needs
    `threshold` seats on the same proposal while eligible; cancellation needs `cancelThreshold` guardian votes.
    A seat replaced by kind 3 loses its approval. Eligibility: the epoch's client frozen or expired, the channel
    silent for `silence`, or a hold standing on IBCAdmin for `holdPeriod`.
14. **Limits are required for escrowed sends** of an Ethereum-native token: a token with no limits configured cannot
    be sent (and its refunds would have no meter budget). A first limits setting always waits 7 days.
15. **Undecodable parameters are spent at recording** (all kinds are decoded then), not only at execution.
16. **Kind 7's after-checks** read authority and bindings; a UUPS proxy's implementation slot is not readable
    on chain, so "implementation moved" is not checked for the router and the transfer app (it is for beacons).

## Tests

`contracts/test/controls/` drives the real `ICS26Router` (mock light client) through the full deployment of
`DeployGnoIBC`: `GnoICS20Transfer.t.sol`, `UpgradeCompat.t.sol`, `IBCAdminDelivery.t.sol`, `IBCAdminKinds.t.sol`,
`IBCAdminRecovery.t.sol`, `IBCAdminHoldFuzz.t.sol`, `Integration.t.sol`, `GovVectors.t.sol`. Library and client
tests: `Guardians.t.sol` (differential fuzz against a model), `LeakyBucket.t.sol`, `Quarantine.t.sol`.
