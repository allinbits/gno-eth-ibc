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
| `IBCAdminExec` | `contracts/src/admin/IBCAdminExec.sol` | The executor: every kind at recording and at execution. Delegatecalled at a pinned code hash; replaced only by kind 9. |
| `IBCAdminRecovery` | `contracts/src/admin/IBCAdminRecovery.sol` | The optional emergency route replacement (§7.12). Deployed by the executor (so pinned with it) and delegatecalled by IBCAdmin. |
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
  flags, quarantine seconds and the deadline of transitions already seen, recovery block, `closed`; per (route,
  token): limits, receive bucket, refund bucket, refund queue, recorded losses; per (client id, sequence): the send
  record and a sender notification held until its refund is paid. Guardian keys carry the block each seat's key was
  set at, so a flag stands only if the current key set it since then.
- **`gno.storage.IBCAdmin`** (`IBCAdminStorage.Layout`): epoch, last seq, epoch client, last record time, conflict
  flag, executor and its code hash, decisions and tombstones keyed by epoch, guardian keys and flags, hold history,
  recovery state, `setupDone`, the decision that last set each setting (`appliedSeq`), gno.land's chain id.

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

As ADR §5.4 has it (amended 2026-10-16 with the implementation):

- Payload: `sourcePort = "gov"`, `destPort = "ibcgov"`, `version = "ibcgov-1"`, `encoding = "application/x-ibcgov"`.
- Envelope: `version u8 (1) ‖ epoch u32 ‖ seq u64 ‖ kind u8 ‖ params`, big-endian, at most 1024 bytes;
  `params = abi.encode(field1, field2, …)` of the kind's tuple (no outer offset).
- App ack: `epoch u32 ‖ seq u64 ‖ status u8 ‖ redispatch u8` (14 bytes); status 1 recorded, 2 buffered,
  3 duplicate, 4 conflict, 5 spent. A cancel beyond the window is acknowledged `status 2, redispatch 1`.
- Every refusal is an error acknowledgement (the router's universal error ack; the custom error is only in the
  router's `IBCAppRecvPacketCallbackError` event): wrong port/version/encoding/client, undecodable envelope, other
  epoch (`StaleEpoch`), beyond the window (`BeyondWindow`), a decision starved of gas (`ExecutionStarved`).
- Byte-exact vectors for kinds 1–13 and every ack: `contracts/test/fixtures/gov-vectors.json`, written and checked
  by `contracts/test/controls/GovVectors.t.sol` (`WRITE_GOV_VECTORS=true` rewrites it).

## ADR rules and where they are implemented

| Rule | Where |
|---|---|
| E5 receive limits per (route, token): max per message + leaky-bucket day cap, in `onRecvPacket` only, before minting or releasing | `GnoICS20Transfer._chargeReceive`; `LeakyBucket` |
| a limits change settles both buckets at the old caps first, so a new cap never rewrites past drainage | `GnoICS20Controls.setLimits`; `LeakyBucket.settle` |
| E5 refunds exempt from receive limits; `GnoVoucher.mint`/`Escrow.send` unlimited; eureka's escrow rate limit unset | refunds go through `_settleRefund`, never `_chargeReceive` |
| E6 default deny: a gno denom without a registered voucher (and limits) is refused, no IBCERC20 ever created | `onRecvPacket` (`GnoDenomNotRegistered`, `GnoLimitsNotSet`); `_getOrCreateIBCERC20` removed |
| E6 expected refusals revert with non-empty custom errors (router → error ack) | `IGnoICS20ControlsTypes` errors |
| E6 send limits for escrowed (Ethereum-native) tokens only (`sendMax`/`sendMin`, 0 = unset); returning vouchers never limited or paused | `_checkEscrowedSend`, skipped when `burned` |
| E6/§7.13 send record in every send variant after `sendPacket` returns the sequence (`sendTransfer`, `…WithPermit2`, `…WithSender`) | `_recordSend` (all three go through `_sendTransferFromEscrowWithSender`) |
| §7.13 records hold the router's commitment, not the packet bytes (bytes in `SendPacket`, authenticated against it); a packet sent before the fork is processed only after a permissionless `backfill(packet)` authenticated its record | `_recordSend`; `GnoICS20Controls.backfill`; `_processed` (`GnoNoSendRecord`) |
| §7.13 ack/timeout attach outcome, local processing block and payment state | `_processed`, `_recordOutcome`, `_settleRefund` |
| §7.13 refund meter per (route, token), queue beyond it, permissionless `claim` (installments) | `_settleRefund`; `GnoICS20Controls.claim` |
| a refund the token or escrow refuses (blacklisted sender, paused token) is parked, never blocking the ack or the queue; `claimParked` retries it | `GnoTransferStorage.tryPayRefund`; `claim`, `claimParked` |
| a sender's `IIBCSenderCallbacks` notification of an error ack or timeout is delivered when its refund is paid (at once, at claim, or by kind 12); a failing notification is recorded and never rolls the refund back | `GnoICS20Transfer._notice`; `GnoTransferStorage.notify/holdNotice/releaseNotice` |
| §7.13 refunds hold suspends proof-based refunds and claims, cancels nothing, follows the ordinary flag and hold rules | route `refundFlags`; `setRefundsFlag`/`clearRefundsFlag`; `unpauseRoute`; checked in `_settleRefund`, `claim`, `claimParked` |
| §7.3 a pause never blocks acks, timeouts or refunds; PAUSER_ROLE granted to nobody | `whenNotPaused` removed from the ack/timeout callbacks; deployment roles |
| E7 4 guardian + 2 watch seats, flags, holds (two guardian flags), 24 h hold end, unpause clears earlier flags, refused under a hold | `Guardians`; per route in the fork, on IBCAdmin itself |
| a replaced key's flags die on every flag set, and stay dead if the key returns (seat generations) | `Guardians.Keys.since`, `setKeys`, `standing` |
| E7 route flags block receives and Ethereum-native sends only | `_checkReceiveRoute`, `_checkEscrowedSend` |
| E9 live-epoch quarantine, anchor-independent; a duration applies to transitions accepted after it, a started quarantine keeps its deadline; governance not quarantined | `GnoLightClient._isLiveTransition`, `lastTransitionTime`; `GnoTransferStorage.quarantineUntil`; `setQuarantine` settles; never checked by IBCAdmin |
| §5.4 envelope, acks, statuses, window W = 64, drain D = 8 (every delivery and `drain()`), duplicates, conflicts | `IBCAdmin.onRecvPacket`, `_deliver`, `_record`, `_drain` |
| §5.4 cancels anywhere: tombstones on arrival of the ranges as given (≤ 64 merged per epoch), a cancel beyond the window bound to its hash, redispatch | `IBCAdmin._deliver`, `_parseCancel`, `_tombstone`; `IBCAdminStorage.addTombstone` |
| §5.4 epochs: another epoch refused, everything keyed by (epoch, seq) | `IBCAdmin.onRecvPacket`; `IBCAdminStorage.Layout` |
| §5.4 unknown kind / bad params recorded and spent; a decision failing its checks at execution spent (no code, another code hash, a refused call, failed after-checks, rolled back) | `IBCAdmin._record`, `execute`; `IBCAdminExec.atRecording`, `_codeIs`, `_call`, `_selfStep` |
| no one spends a decision by starving it of gas: recording, refusable calls and self-steps run with fixed budgets and floors | `IBCAdmin._atRecording`; `IBCAdminExec._call`, `_selfStep` |
| §5.4 kind delays: cancel / kind 4 tightening / kind 8 revoke / kind 11 lengthening at recording; unpause 24 h; others 7 d | `IBCAdminExec.atRecording`, `IBCAdmin.execute`, `_delay` |
| §6.6/§7.4 7-day kinds deferred by flags and holds; kind 3 through flags, through a hold at ≥ day 21 | `IBCAdmin.execute`, `_replacementFloor` |
| §7.4 unpause spent under a hold of its object (a route: its flags or refunds flags) | `IBCAdminExec._unpause` |
| kind 3 at most 2 guardian seats, never a current key; both key copies follow; a replaced seat loses its recovery approval | `Guardians.checkReplace`; `IBCAdminExec._seats` |
| kind 4 limits, "no field loosens" rule; an older decision maturing later never overwrites a newer setting (kinds 4, 11) | `IBCAdminExec._loosens`; `IBCAdminStorage.supersede` |
| kind 5 voucher registration, code-hash pinned, bound to the fork | `IBCAdminExec._voucher` |
| kind 6 add (custom id) / migrate a client, code-hash pinned | `IBCAdminExec._client` |
| kind 7 upgrades (router, transfer app, its two beacons), code-hash pinned, fixed call gas, after-checks, no nested `upgradeToAndCall`/`multicall` in the call, rolled back whole on failure | `IBCAdminExec._upgrade`, `applyUpgrade` |
| kind 8 relayer role only; never ADMIN or any role that upgrades or re-points | `IBCAdminExec.atRecording`/`run` |
| kind 9 hand-over: swap the pinned executor (same bindings), optional migration call, rolled back whole on failure | `IBCAdminExec._handover`, `applyHandover` |
| kind 10 / E12 route replacement: retire + freeze the old id, `migrateRoute` (the route closes), next epoch over the new id | `IBCAdminExec._route`; `IBCAdminStorage.replaceRoute`; `GnoICS20Controls.migrateRoute` |
| kind 11 route quarantine setting | `IBCAdminExec.atRecording`/`run`; `GnoICS20Controls.setQuarantine` |
| kind 12 settle: per send record of a retired client id, at most once, all or nothing: 1 pay a refund ≤ entitlement − refunded (parked if refused), 2 reject a queued refund, 3 settled as delivered, 4 record a loss | `IBCAdminExec.run`; `GnoICS20Controls.settleRecords` |
| kind 13 reopen a closed route; a closed route refuses receives, sends and claims | `GnoICS20Controls.reopenRoute`; `_checkReceiveRoute`, `_sendTransferFromEscrowWithSender`, `_openRoute` |
| E12 route keys, constant-work migration, wire translation | `GnoTransferStorage.routeKey/toRouteDenom/toWireDenom`; `migrateRoute` |
| §7.12 emergency recovery, off unless enabled at deployment; approval ≥ 3 of 4 guardians, cancellation ≥ 2 of 4; eligibility; an attested client of gno.land's chain id, neither frozen nor expired at approval and at execution; long delay; suspends kinds 3, 6–10 at recording and at execution; blocks receives while open; the route stays closed after it | `IBCAdmin` constructor, `approveRecovery/cancelRecovery/executeRecovery`; `IBCAdminRecovery` |
| E4/E11 hand-over of every authority, deployer roles removed, check list read back | `script/DeployGnoIBC.s.sol`; `IBCAdmin.finishSetup`; `IBCAdminSetupCheck` |
| §7.2/§9 launch values from the expected lock: day cap min(100,000 GNOT, lock/10), max per message min(25,000 GNOT, day cap), refund cap the day cap; overrides only lower; quarantine 7 d | `DeployGnoIBC._launchLimits`, `_deploy` |

## Divergences from the ADR

The amended ADR (2026-10-16) now specifies the port `ibcgov`, the 1024-byte envelope, custom client ids, the ack of
a cancel beyond the window, commitment-only send records with `backfill`, and kinds 12 and 13. What remains:

1. **The router has no freeze**: the old client id of a route replacement is `migrateClient`ed to
   `FrozenLightClient`, which proves nothing.
2. **Quarantine duration is the route's (kind 11), not the client's.** The client records the time of its latest
   live transition; the transfer app fixes each transition's deadline with the duration in force when it is first
   seen, and a duration change settles the deadlines of transitions accepted before it.
3. **Pause flags and the refunds hold are per route; IBCAdmin's flags are per object** (kind 2: object 1 = a route,
   object 2 = IBCAdmin). Guardian keys are global: IBCAdmin keeps them and pushes a copy to the transfer app on
   every kind 3.
4. **Kind 2 on a route clears both its pause flags and its refunds flags** set before the decision, and is spent
   while either flag set holds.
5. **Kind 10 is also suspended while an emergency recovery is open** (the ADR lists kinds 3 and 6–9).
6. **Limits are required for escrowed sends** of an Ethereum-native token, and a token's first limits setting always
   waits 7 days.
7. **Undecodable parameters are spent at recording** (all kinds are decoded then).
8. **Kind 7 cannot read a UUPS proxy's implementation slot on chain**: after-checks read authority and bindings, and
   the call may not itself be an `upgradeToAndCall` or `multicall` (a nested upgrade to unpinned code). Beacons are
   checked exactly.
9. **Kind 12 pays refunds outside the refund meter** (a governed decision) and only for records of a retired client
   id.

## Upgrade runbook (installing the fork on a live ICS20 proxy)

1. Stop relaying acknowledgements and timeouts to Ethereum.
2. Execute the upgrade (kind 7 on a governed deployment; `upgradeToAndCall(fork, initializeGno(keys))` before the
   hand-over).
3. For every packet the router still holds a commitment for (`SendPacket` events without a matching ack or
   timeout), call `backfill(packet)` with the event's packet bytes; anyone may. A callback for a packet without a
   record reverts (`GnoNoSendRecord`) and leaves the commitment in place, so nothing is lost if one is missed: backfill
   it and relay again.
4. Set limits (kind 4) for every token with outstanding packets, or their refunds queue with no budget.
5. Resume relaying.

## Open issues

- **A newly added client starts unquarantined.** A client installed by kind 6, kind 10 or the emergency recovery
  has no transition until its first one. Marking construction as a transition would also quarantine the launch client.
- **Parking under starvation.** A relayer giving an ack too little gas for the token transfer can make a refund be
  parked instead of paid; it stays owed and `claimParked` pays it.
- **The deployer cannot be the relayer** (`RELAYER_ADDRESS`): check 2 refuses any role left with the deployer.
- `scripts/e2e-local.sh` was not run end to end (it needs the gno testnet); the deployment it runs was broadcast to a
  local anvil and `finishSetup` passed.

## Tests

`contracts/test/controls/` drives the real `ICS26Router` (mock light client) through the full deployment of
`DeployGnoIBC`: `GnoICS20Transfer.t.sol`, `UpgradeCompat.t.sol`, `IBCAdminDelivery.t.sol`, `IBCAdminKinds.t.sol`,
`IBCAdminRecovery.t.sol`, `IBCAdminHoldFuzz.t.sol`, `Integration.t.sol`, `ReviewRegressions.t.sol`,
`GovVectors.t.sol`. Library and client tests: `Guardians.t.sol` (differential fuzz against a model),
`LeakyBucket.t.sol`, `Quarantine.t.sol`. Foundry runs in Docker, image `ghcr.io/foundry-rs/foundry:v1.7.1` (pinned:
under 1.8.1 the pre-existing `GasScaling` test runs out of gas).
