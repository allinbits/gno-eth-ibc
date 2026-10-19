# Ethereum controls (ADR pr6375 E5–E9, E11, E12)

The Ethereum side of the safety and governance controls of the gno.land ⇄ Ethereum IBC ADR
(`gno.land/adr/pr6375_ibc_ethereum.md` in the gno repository, §4.4, §5.4, §6–§7, §9). This page lists what is
built, where each rule lives, and where the implementation departs from the ADR.

## Trust assumptions

The controls are safe under these assumptions; each is detailed where its rule is.

- **Ethereum's client of gno.land** (GnoLightClient) is honest until a compromise is found and the route replaced;
  the quarantine, the guardians' holds and reconciliation bound what a compromise can do before that.
- **gno.land's client of Ethereum** is trusted for governance too: a compromised approved gno-side verifier can move
  gno.land's governance epoch wrongly, repaired only by Ethereum's emergency recovery if enabled, and a poisoned
  client gno.land keeps Active blocks a catch-up past 64 epochs ("Trust in gno.land's Ethereum verifier" below).
- **Governance** (gno.land's GovDAO through ibcgov) and the **guardians** act as the ADR describes.
- **Tokens** enrolled for escrow have exact transfers, truthful balances and stable balances; their issuers' seizure,
  rebase and upgrade powers are trusted ("Supported tokens" below).
- **Relaying is public** (anyone can relay governance, notices and transfers); `submitMisbehaviour` is always public.

## Contracts

| Contract | File | What it is |
|---|---|---|
| `GnoICS20Transfer` | `contracts/src/GnoICS20Transfer.sol` | Minimal fork of eureka v3.0.2 `ICS20Transfer` (MIT); its changes are marked `GNO:`, except the `nonReentrant` modifiers added to entry points that upstream leaves without one (`pause`, `unpause`, `setCustomERC20`, `upgradeEscrowTo`, `upgradeIBCERC20To`), which carry no marker (a diff against `lib/solidity-ibc-eureka/contracts/ICS20Transfer.sol` lists every change). Deployed as the ICS20 proxy's first implementation (`DeployGnoIBC`); later versions are installed only by kind 7 (the proxy's UUPS upgrade). Hot path of the controls: receive checks and limits, send checks and send records, refunds (paid, metered, queued, held). |
| `GnoICS20Controls` | `contracts/src/transfer/GnoICS20Controls.sol` | The controls' governance setters, guardian flags, `claim`, views, and `ackHook` (the fork's ack/timeout settlement, reachable only through the fork's own call: a consume-once transient flag). Runs only by delegatecall from the fork: through `GnoICS20Transfer`'s `fallback` for ordinary calls, and through a direct delegatecall from the fork's `_ackHook` for the ack and timeout settlement (EIP-170 keeps them apart); its address is an immutable of the fork's implementation. |
| `GnoICS20Reconcile` | `contracts/src/transfer/GnoICS20Reconcile.sol` | Reconciliation: `claimParked`, `settleRecords` (kind 12), `reopenRoute` and `continueReopen` (kind 13). Reached through `GnoICS20Controls`' fallback; its address is an immutable of the controls. |
| `GnoICS20Evidence` | `contracts/src/transfer/GnoICS20Evidence.sol` | Evidence: `proveOutcome`, `gnoReceipt`, `receiveRecord`, `notifySettled`, `retryNotification`, and the `incidents` and `clientRecon` views. Reached through `GnoICS20Reconcile`'s fallback; its address is an immutable of the reconciliation module. |
| `GnoTransferStorage` | `contracts/src/transfer/GnoTransferStorage.sol` | The fork's ERC-7201 layout (`gno.storage.GnoICS20Transfer`) and the route-key helpers both halves use. |
| `IBCAdmin` | `contracts/src/admin/IBCAdmin.sol` | Permanent, immutable IBC app on port `ibcgov`: the §5.4 delivery protocol, the decision ledger, flags on itself, execution scheduling, recovery entry points, `finishSetup`. Holds `ADMIN_ROLE`. |
| `IBCAdminExec` | `contracts/src/admin/IBCAdminExec.sol` | The executor: kinds 2 to 13 at recording and at execution (kind 1, the cancel, is handled by IBCAdmin itself: its tombstones are applied on arrival). Delegatecalled at a pinned code hash; replaced only by kind 9. |
| `IBCAdminRecovery` | `contracts/src/admin/IBCAdminRecovery.sol` | The optional emergency route replacement (§7.12). Deployed by the executor (so pinned with it) and delegatecalled by IBCAdmin. |
| `IBCAdminStorage` | `contracts/src/admin/IBCAdminStorage.sol` | IBCAdmin's ERC-7201 layout (`gno.storage.IBCAdmin`), constants, tombstones, hold history. |
| `IBCAdminChecks` | `contracts/src/admin/IBCAdminChecks.sol` | The executor's stateless checks (a view contract it deploys): canonical parameters per kind, gno.land denoms and counterparties, and whether a light client may verify for gno.land (code, chain id, neither frozen nor expired, a last transition), every status view failing closed. |
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
  of the custom-ERC20 registry are keyed by **route key**, which equals the client id until a route is migrated.
  The deployment is fresh on both chains: `GnoICS20Transfer` is the ICS20 proxy's first implementation, so no
  packet predates the controls and every packet has a send record (there is no backfill and no legacy record).
- **`gno.storage.GnoICS20Transfer`** (`GnoTransferStorage.Layout`):
  - guardian keys (IBCAdmin's copy; each seat carries a monotonic generation `gen`, and each flag stores the block,
    time, key and generation that set it, so a flag stands only if the seat's current key set it), `routeOf`
    (client id → route key), `currentOf` (route key → current client id), `retired`;
  - per route (`Route`): pause flags, refunds flags, quarantine seconds, `quarantineArmed`, the deadline of the
    transitions already seen, recovery block, `closed`, `reopening` and the deficit cursor, the verifier generation
    (bumped before every verifier swap and replacement), the incidents with their two bounds (`resolvedUpTo`,
    `reopenUpTo`), `pendingIncidents`, `unprepared`, and the tokens with losses;
  - per (route, token): limits, receive bucket, refund bucket, refund queue, the escrow reserved for owed refunds and
    outstanding sends, recorded losses and the part accepted as a deficit;
  - per client id (`ClientRecon`): the blocks and sequences of every ack and timeout it processed (append-only, in
    order), its open-record count, and once retired its incident, first suspect index `suspectStart`, unsettled
    suspect count, and preparation cursor (`prepCursor`, `prepared`);
  - per (client id, sequence): the send record (commitment, sender, token, escrow, amount, open flag, outcome,
    payment state, refunded amount, settlement, proven destination outcome with its verifier and verifier
    generation, `held`, its index in its client's processed list), the hash of a sender notification held until its
    refund is paid or kept after a failed delivery (never its bytes), whether that notification is done, whether a
    settlement's notification is done, and the hash of the success ack `proveOutcome` proved;
  - per (client id, inbound sequence): every receive's token and amount in one slot; kind 12 action 5 clears the
    amount when it books the receive as a loss, so `receiveRecord` then answers the token and zero (the booked
    amount is in the settlement's `GnoSettled` event); every booked loss by its
    canonical identity (client, sequence, direction).
  - A replacement on IBCAdmin's key list reaches the transfer app's copy (`setGuardianKeys`), which retires the
    replaced keys' flags by generation without touching that flag set's hold moments.
  - The hold reads them lazily: a hold left with fewer than two standing guardian flags and no dip ends.
  - So does a dip in which a guardian flag that stood when the dip started is still set but no longer stands. Its
    key was replaced (`dipMask` records the seats standing at the dip's start), and this ends the hold at once, as a
    replacement on the same flag set does. An owner's own clear keeps the 24-hour grace.
- **`gno.storage.IBCAdmin`** (`IBCAdminStorage.Layout`): epoch, last seq, epoch client, last record time, conflict
  flag, executor and its code hash, decisions and tombstones keyed by epoch, guardian keys and flags, hold history,
  recovery state, `setupDone`, the decision that last set each setting (`appliedSeq`), gno.land's chain id, the client
  ids kind 6 added (`enrolled`, the only ids kind 10 may move a route to), each epoch's notice, and each pending seat change's anchor (`seatAnchor`).

## Roles (AccessManager)

| Function | Role | Holder after the setup |
|---|---|---|
| the fork's, the controls', the reconciliation and evidence modules' state-changing entry points (sends, packet callbacks, claims, guardian flags, governed setters, settlement and reopening, proofs, notifications, `setCustomERC20`, the beacon upgrades) acquire one shared transient reentrancy lock; `gnoBusy()` reads it. The transfer proxy's UUPS upgrade (`_authorizeUpgrade`) only refuses while the lock is held and does not acquire it; eureka's initializers `initialize` and `initializeV2` and its `multicall` wrapper hold no enclosing lock (each inner call takes its own); `initializeGno` acquires the lock | the lock | — |
| everything governed: router `addIBCApp(string,…)`, `addClient(string,…)`, `migrateClient`, `upgradeToAndCall`; transfer `setCustomERC20`, `upgradeToAndCall`, beacons, every control setter (`initializeGno`, `setGuardianKeys`, `setLimits`, `setQuarantine`, `unpauseRoute`, `setRecoveryBlock`, `migrateRoute`) | `ADMIN_ROLE` | `IBCAdmin` only |
| `recvPacket`, `ackPacket`, `timeoutPacket`, `updateClient` | `PUBLIC_ROLE` in production; `RELAYER_ROLE` only in a testing deployment (`RELAYER_ADDRESS` with `ALLOW_RESTRICTED_RELAYING=true`) | anyone (production) / kind 8 |
| router `submitMisbehaviour` | none: permissionless whatever the relaying setting | anyone |
| route flags: transfer `setRouteFlag`/`clearRouteFlag` (pause) and `setRefundsFlag`/`clearRefundsFlag` (refunds hold); IBCAdmin `setFlag`/`clearFlag` (after `finishSetup`) | a guardian or watch key, for its own flag only | the six keys |
| transfer `pause` / `unpause` | `PAUSER_ROLE` / `UNPAUSER_ROLE` | nobody (ADR §7.3) |
| `sendTransferWithSender` | `DELEGATE_SENDER_ROLE` | nobody |

The deployer never holds `ID_CUSTOMIZER_ROLE` or `ERC20_CUSTOMIZER_ROLE` (those functions are `ADMIN_ROLE`'s) and
renounces `ADMIN_ROLE` at the end of `DeployGnoIBC`, which then runs `IBCAdmin.finishSetup(launch)`.

**Relaying stays public in production.** eureka's router restricts `recvPacket`, `ackPacket` and `timeoutPacket` per
function, never per port. So a relayer allow-list cannot be scoped to transfers: it would gate IBCAdmin's governance
delivery and the epoch-notice acknowledgements as well, and the only way to restore relaying access (a kind 8 grant)
arrives over that very delivery. A lost relayer key would lock governance out for good, and the emergency recovery
replaces the route, not the relayer permissions. `DeployGnoIBC` therefore refuses `RELAYER_ADDRESS` unless
`ALLOW_RESTRICTED_RELAYING=true` is set, which is for testing only (`test_d1_restrictedRelaying_refusedWithoutTheTestingFlag`).

Operating views: `routeClosed`, `routeReopening`, `routeFlags`, `routeHold`, `refundsHold`, `refundsHeld`,
`sendRecord`, `openRecords`, `reserved`, `losses`, `acceptedDeficit`, `incidents`, `clientRecon`, `receiveRecord`,
`quarantineEnd` on the transfer app; `epoch`, `lastSeq`, `govClient`, `decision`, `tombstones`, `flags`, `hold`,
`holds`, `recovery`, `recoveryConfig`, `epochNotice`, `epochNoticeAcked` on IBCAdmin.

## The governance wire format (for `ibcgov`)

As ADR §5.4 has it (amended 2026-10-16 with the implementation):

- Payload: `sourcePort = "gov"`, `destPort = "ibcgov"`, `version = "ibcgov-1"`, `encoding = "application/x-ibcgov"`.
- Envelope: `version u8 (1) ‖ epoch u32 ‖ seq u64 ‖ kind u8 ‖ params`, big-endian, at most 1024 bytes;
  `params = abi.encode(field1, field2, …)` of the kind's tuple (no outer offset). A readable envelope longer than
  1024 bytes is not refused for its size: within the window it is taken (buffered if early), consumes its number,
  and is spent when recorded (status 5); beyond the window it is an error ack, as any non-cancel
  (`IBCAdminDelivery.t.sol`).
- App ack: `epoch u32 ‖ seq u64 ‖ status u8 ‖ redispatch u8` (14 bytes); status 1 recorded, 2 buffered,
  3 duplicate, 4 conflict, 5 spent. A cancel beyond the window is acknowledged `status 2, redispatch 1`.
- A conflict (other bytes at a recorded or buffered number) keeps the first bytes and sets IBCAdmin's conflict
  flag, which defers every 7-day decision. The flag's block is refreshed on every conflict, and a kind 2 unpause
  clears it only when the latest conflict came strictly before the unpause was recorded. Guardian flags work the
  same way: setting one again refreshes its block. Hold and dip moments keep their first block, but only to measure
  how long a hold has lasted; no unpause is compared against them.
- One exception, which is not a refusal of the packet: a delivery made from inside a transfer-app entry point (a token,
  permit2 or sender hook relaying while relaying is public) reverts with no data. The router then reverts the whole
  delivery (`IBCFailedCallback`), writes nothing, and the packet is relayed again later. This holds for IBCAdmin and
  the transfer app alike.
- Every refusal is an error acknowledgement (the router's universal error ack; the custom error is only in the
  router's `IBCAppRecvPacketCallbackError` event): wrong port/version/encoding/client, undecodable envelope, other
  epoch (`StaleEpoch`), beyond the window (`BeyondWindow`), a decision starved of gas (`ExecutionStarved`).
- **Epoch notice (ADR §7.12, the two-phase epoch switch).** Every executed kind 10 or emergency recovery raises the
  epoch by one and sends that epoch's notice from IBCAdmin's port `ibcgov` over the epoch's NEW client to gno.land's
  `gov` port: payload `sourcePort "ibcgov"`, `destPort "gov"`, `version "ibcgov-1"`, `encoding
  "application/x-ibcgov"`, value `version u8 (1) ‖ epoch u32 BE ‖ clientId`, the client id as raw trailing bytes
  (no length) and equal to the packet's source client. Its timeout is a fixed 23 hours.
  - gno.land answers in IBCAdmin's ack layout, `epoch u32 ‖ seq u64 (0) ‖ status u8 ‖ redispatch u8 (0)`. Status 1
    (switched) or 3 (already switched) for that epoch, with sequence 0 and redispatch 0, marks the notice
    **acknowledged** (`epochNoticeAcked(epoch)`); any other value of any field does not. An ack of an epoch already
    acknowledged is ignored, and nothing ever clears the mark. gno.land answers a notice it recorded as proven but
    has not applied (an advance of more than one epoch), a competing transition and every other refusal with the
    universal error ack.
  - **A recorded notice is always re-sendable** (a send the router refuses, from inside its lock, is reported with
    sequence 0 and the call can simply be repeated). `resendEpochNotice(epoch)` works for any epoch whose notice was
    recorded (every epoch a kind 10 or the emergency recovery opened; never the launch epoch), at any time: before
    or after an acknowledgement, and whatever the current epoch. It is permissionless: a notice states a fact and
    gno.land de-duplicates it. An acknowledgement never closes it, because a compromised Ethereum-side gno.land
    verifier could authenticate forged acks for many epochs. Each resend sends the identical bytes in a **fresh
    packet** (`router.sendPacket`, a new transport sequence) over **that epoch's own client**, even one Ethereum has
    since retired. eureka's `sendPacket` reads only the client's counterparty, never its light client. So neither
    the retirement (the id migrated to the frozen light client) nor a frozen verifier blocks it. A resend changes
    nothing on Ethereum but the notice's last sequence; its timeout changes nothing, and its ack changes nothing
    for a notice already acknowledged (one not yet acknowledged has its informational `acked` mark set by a status 1
    or 3 ack)
    (`test_r22_resendAfterAck_freshPacket_repeatAckIgnored`, `test_r22_resendOverARetiredClient`,
    `test_r22_resendOldEpoch_changesNothing`, `test_r22_timeoutOfAnAckedResend_changesNothing`). A resend over a
    client Ethereum retired can be neither acknowledged nor timed out on Ethereum (the frozen client verifies
    nothing). It stays committed, harmlessly.
  - A recorded notice applies on gno.land only while the client that proved it is Active, not retired, and at the
    same trust generation; otherwise it must be proven afresh. Relaying the original packet again does not do
    that: its receipt exists, so the gno core answers `RESPONSE_NOOP` before any proof or callback. The operator
    relays a fresh packet from `resendEpochNotice(epoch)` instead.
  - **What gno.land answers to resends.** A resend of the current epoch's notice over its own client: status 3
    (duplicate). A resend of a competing transition: the universal error ack. A resend of an epoch gno.land has
    already passed, over a client gno.land retired for its gov port, is refused by gno's core. The relay transaction
    aborts, no ack returns, and the packet times out on Ethereum if its client there can still verify one. That is
    harmless: a passed epoch's notice is never needed again.
  - **No cap on unacknowledged advances.** Ethereum puts no bound on how far its epoch runs ahead of gno.land's
    acknowledgements. A cap could block the emergency recovery after the latest client froze before it verified an
    ack. gno.land bounds its own work instead: it accepts a notice whose explicit path lies in its expected graph,
    and it caps both that graph and each notice's path at 64 transitions.
  - **Catch-up when gno.land is more than 64 epochs behind.** gno.land advances in bounded prefixes. It applies a
    prefix of at most 64 transitions, records the next expectations, and repeats. The operator drives it by
    resending the intermediate epochs' notices in order (`resendEpochNotice(e)` for each epoch `e` past gno.land's
    current one, each over its own client) and relaying each fresh packet. It continues until a resend of the
    current epoch's notice is answered with status 1 or 3. **Preconditions:** gno.land's local clients of Ethereum
    along the path are honest, and none is a poisoned client gno.land keeps Active (one that is blocks the catch-up
    past 64 until it is frozen or expires and is recovered in place, which also needs an honest, independently
    authenticated substitute client ahead of it; without one, catch-up past it can fail for good); a forged notice gno.land already applied is
    not repaired by resends, only by Ethereum's emergency recovery, if enabled ("Trust in gno.land's Ethereum
    verifier" below). If an intermediate gno-side local client has failed,
    gno.land recovers it in place (`NewRecoverClientRequest`: the same client id, a new trust generation). The
    resent notice is then proven through it, so Ethereum's notice packets stay addressed to the same counterparty
    id. A fresh gno.land local client applies only when Ethereum's emergency recovery created a new router client.
  - Each epoch keeps its own notice, so after consecutive replacements (A→B→C: epoch 2 over B, epoch 3 over C) each
    stays re-sendable on its own, and gno.land may skip ahead.
  - The ack and timeout callbacks handle notices and ignore anything else; called by the router they never revert,
    and any other caller is refused (`NotRouter`).
  - Example (`epochNotice` in the vectors file): epoch 2 over `gnoland-2` is `0x0100000002676e6f6c616e642d32`; the
    switched ack is `0x0000000200000000000000000100`, the duplicate ack `0x0000000200000000000000000300`.
- **Route identity.** Every replacement path (kind 6 add or migrate, kind 10, the emergency recovery) requires the
  verifier to follow IBCAdmin's gno.land chain id, which `finishSetup` checked against the launch client, and the
  counterparty to use gno.land's exact store prefix. The route's identity is therefore preserved; a client of
  another gno chain or store is refused (`test_routeIdentity_anotherGnoChain_refusedOnEveryPath`).
- **Kind 10 is all or nothing.** The quarantine checkpoint (which bumps the route's verifier generation and voids
  the old verifier's proofs), the route's migration and the epoch switch run in one frame. A refused migration (for
  instance a target that already has an escrow) rolls the checkpoint back, and the decision is spent: outcomes proven
  before stay usable and cannot be voided (`test_r19_3_refusedKind10_keepsTheProofs`).
- **An initial notice send can be refused** (for instance when the kind 10 is executed from inside another app's
  receive callback, with the router locked). The epoch switch stands and the notice is sent by
  `resendEpochNotice` (`test_epochNotice_refusedInitialSend_resendCompletes`).
- **Vacancies are not supported** (a divergence: ADR §7.4 allows them, subject to the replacement delays). Kind 3
  never sets a seat to no key (`Guardians.checkReplace`): such a decision is spent at recording.
- Byte-exact vectors for kinds 1–13 and every ack: `contracts/test/fixtures/gov-vectors.json`, written and checked
  by `contracts/test/controls/GovVectors.t.sol` (`WRITE_GOV_VECTORS=true` rewrites it).

## ADR rules and where they are implemented

| Rule | Where |
|---|---|
| E5 receive limits per (route, token): max per message + leaky-bucket day cap, in `onRecvPacket` only, before minting or releasing | `GnoICS20Transfer._chargeReceive`; `LeakyBucket` |
| a limits change settles both buckets at the old caps first, so a new cap never rewrites past drainage | `GnoICS20Controls.setLimits`; `LeakyBucket.settle` |
| E5 refunds exempt from receive limits; `GnoVoucher.mint`/`Escrow.send` unlimited; eureka's escrow rate limit unset | refunds go through `ackHook`, never `_chargeReceive` |
| E6 default deny: a gno denom without a registered voucher (and limits) is refused, no IBCERC20 ever created | `onRecvPacket` (`GnoDenomNotRegistered`, `GnoLimitsNotSet`); `_getOrCreateIBCERC20` removed |
| E6 expected refusals revert with non-empty custom errors (router → error ack) | `IGnoICS20ControlsTypes` errors |
| E6 send limits for escrowed (Ethereum-native) tokens only (`sendMax`/`sendMin`, 0 = unset); returning vouchers (burns over the current, non-retired client) never limited, paused or blocked by a closed route or an open recovery: an exit, whose refund, if any, waits for the route's reopening; an escrowed send is refused on a closed route (`GnoRouteClosed`) and while a recovery is open (`GnoRouteRecovering`) | `_checkEscrowedSend`, skipped when `burned` (`test_d8_closedRoute_voucherBurnExits_nativeRefused`) |
| ADR §9 payload bound: a transfer packet's encoded payload value is at most 262,144 bytes, checked on every send (the shared send path, before `sendPacket`) and on every receive before any decoding (`GnoPayloadTooLarge`; a receive above it is an error ack) | `GnoICS20Transfer._sendTransferFromEscrowWithSender`, `onRecvPacket` (`test_r26_5_payloadBound_everySendVariant`, `test_r26_5_payloadBound_receive`) |
| E6/§7.13 send record in every send variant after `sendPacket` returns the sequence (`sendTransfer`, `…WithPermit2`, `…WithSender`) | `_recordSend` (all three go through `_sendTransferFromEscrowWithSender`) |
| §7.13 records hold the router's commitment, not the packet bytes (bytes in `SendPacket`, authenticated against it); an ack or timeout without a record is refused (`GnoNoSendRecord`; none can exist on a fresh deployment) | `_recordSend`; `GnoICS20Controls.ackHook` |
| §7.13 ack/timeout attach outcome, local processing block and payment state | `GnoICS20Controls.ackHook` |
| §7.13 refund meter per (route, token), queue beyond it, permissionless `claim` (installments); the meter starts **empty** on a token's first limits (the whole refund cap is available at once), so at a constant cap a full initial budget plus a day's refill allows up to two caps within 24 hours (gno.land starts otherwise, as the ADR records); the meter is charged before the token moves (given back if the payment fails), and its limits cannot change mid-payment (shared lock; IBCAdmin refuses while busy). A refund is paid at once only when the token's queue is empty, the refunds hold does not stand, the route is open and the meter has room for the **whole** refund; otherwise it is queued, with no first installment. `claim(clientId, token, maxCount)` works the queue in order from its head, `maxCount` clamped to 20; it pays the head's remainder as far as the meter allows (a partial installment ends the call), parks a refund its token refuses, skips entries already settled, and returns the number of queue entries it removed (paid in full, parked or skipped), not tokens paid: a partial installment removes nothing | `GnoICS20Controls.ackHook`, `claim` |
| §7.12 escrow per route and token is kept at the reservation (for supported tokens: "Supported tokens" below), with one exception: reconciliation may reveal refunds a forged success ack hid, owed again beyond what the compromise left (e.g. escrow 150 against a reservation of 200, `test_r17_1_twinHiddenRefunds_reservedBeforeAnyPayment`), the shortfall invariant 5 permits. The guards are that no receive and no refund payment consumes another reservation's backing: owed refunds (queued, parked, decided but unpaid) and outstanding escrowed sends (no ack or timeout yet, not settled), whose refund could still be owed. A receive below it is an error ack (`GnoEscrowReserved`); a refund (at once, claim, `claimParked`, kind 12) that would take another record's backing is parked; vouchers reserve nothing | `GnoTransferStorage.reservation/syncReserve/tryPayRefund`; `GnoICS20Transfer.onRecvPacket`, `_recordSend` |
| a refund the token or escrow refuses (blacklisted sender, paused token) is parked, never blocking the ack or the queue; `claimParked` retries it. One exception: a voucher refund first mints into the escrow, and if the escrow's release then fails, the mint is undone by an **unbounded** `burn` on the governance-pinned voucher, whose failure propagates (the voucher's burn is trusted to succeed) | `GnoTransferStorage.tryPayRefund`; `claim`, `claimParked` |
| a sender is notified only if it answers ERC-165 `supportsInterface` true for `IIBCSenderCallbacks` (implementing the callbacks is not enough). The introspection is isolated: OpenZeppelin's `ERC165Checker` makes at most three STATICCALLs (`IERC165`, the invalid id, `IIBCSenderCallbacks`) of 30,000 gas each, copies only the first word of each answer, and treats a revert, a short answer or a zero word as unsupported (a longer answer counts by its first word only, nothing more is copied); so it costs a caller at most about 90,000 gas, which comes before the callback's own 100,000 and the 60,000 reserve, and a sender burning its gas or answering at length cannot stall an ack, a claim or a settlement (`test_d5r1_introspectionBurningGas_refundsAndSettlementComplete`, `test_d5r1_introspectionLongAnswer_refundsAndSettlementComplete`): `notify` and `holdNotice` skip any other sender silently, and `notifySettled` refuses it (`GnoNoNotification`). A sender's `IIBCSenderCallbacks` notification of an error ack or timeout is delivered when its refund is paid at once, with at most 100,000 gas and only when 60,000 more remain for the caller. Only its hash is ever stored (held, or kept after a failure): a claim, `claimParked` or kind 12 paying it only marks it due (`GnoNotificationDue`), and anyone delivers it with `retryNotification(clientId, sequence, call, gasBudget)`, `call` being the callback calldata the router's ack or timeout carried, authenticated against the hash, with a caller-chosen gas budget (a non-zero budget is raised to at least 100,000, and a caller sending too little for it and the 60,000 reserve reverts `GnoNotificationStarved`; a zero budget is the automatic 100,000 and never reverts as starved: `retryNotification(…, 0)` then delivers only if the gas left covers the call and the reserve, else returns false and keeps the hash, and `notifySettled(…, 0)` makes its call without the reserve check); a failing notification never rolls the refund back; a rejected refund's notification is dropped | `GnoTransferStorage.notify/holdNotice/releaseNotice/retryNotice`; `GnoICS20Evidence.retryNotification` |
| one terminal notification per send record. **A transport callback already delivered is final**: when kind 12 later decides the other kind (a forged success ack delivered to the sender contract, then an action 1 refund; or a delivered refund notification, then actions 2 to 4), no second, contradictory terminal callback ever follows (`notifySettled` refuses it), and the reconciliation is reported by the settlement event `GnoSettled(clientId, sequence, action, amount)`, emitted once per record (a record is settled at most once); integrations that took the transport callback reconcile from that event (`test_d5_deliveredForgedSuccess_thenRefund_noSecondCallback`). Otherwise the notification is decided by the final outcome: the transport's (success or refund) until kind 12 settles it, then the settlement's (action 1 a refund, actions 2 to 4 a success). A settlement deciding another kind supersedes a saved, undelivered transport notification (it is never delivered after); a permissionless `notifySettled(packet, ack, gasBudget)` delivers the settlement's once: the refund (`onTimeoutPacket`, synthesized because no refund notification came from the transport) once paid in full, or the success (`onAckPacket(true, …)`) with the ack `proveOutcome` proved (kept as a hash), which covers a delivered outstanding packet settled by action 3; the packet authenticated against the record's commitment, retried by calling again. A success the transport announced but never delivered (the sender refused it) is replaced by the proven one once actions 2 or 3 settle it, even when both are successes: the transport's ack may be forged. After that settlement, `retryNotification` takes only a call carrying the proven ack, and `notifySettled` delivers it once. Delivering through either path marks the other done, so the sender is told of the success exactly once | `GnoICS20Reconcile.settleRecords`; `GnoICS20Evidence.notifySettled`; `GnoTransferStorage.noticeKinds/deliverSettled` |
| §7.13 refunds hold suspends proof-based refunds and claims, cancels nothing, follows the ordinary flag and hold rules; a refund-paying kind 12 (an action 1 item with a non-zero amount) is **deferred** while the route's refunds hold stands (any key's refunds flag): `execute` reverts `Deferred` and the decision stays pending, as on gno.land; a kind 12 paying nothing is not held | route `refundFlags`; `setRefundsFlag`/`clearRefundsFlag`; `unpauseRoute`; checked in `ackHook`, `claim`, `claimParked`; `IBCAdmin.execute` with `IBCAdminChecks.settleHeld` (`test_d6_refundPayingSettlement_pendsUnderTheRefundsHold`) |
| §7.3 a pause never blocks acks, timeouts or refunds; PAUSER_ROLE granted to nobody | `whenNotPaused` removed from the ack/timeout callbacks; deployment roles |
| E7 4 guardian + 2 watch seats, flags, holds (two guardian flags), 24 h hold end, unpause clears earlier flags, refused under a hold | `Guardians`; per route in the fork, on IBCAdmin itself |
| a replaced key's flags die on every flag set, and stay dead if the key returns (seat generations) | `Guardians.Keys.gen`, `setKeys`, `standing` |
| E7 route flags block receives and Ethereum-native sends only | `_checkReceiveRoute`, `_checkEscrowedSend` |
| E9 live-epoch quarantine, anchor-independent; fail closed where it is read: a client whose `lastTransition()` is missing or reverts refuses receives and quarantine changes (`GnoQuarantineUnknown`). The exact-length check (precisely two uint64 words, 64 bytes) is made by the quarantine checkpoints and changes (`GnoICS20Controls._lastTransition`) and by installation (`IBCAdminChecks.transitionKnown`), which refuse anything else; a receive reads it with a typed call, which accepts a longer answer whose first two words decode. **A route replacement never depends on the failing verifier** (`checkpointForReplacement`, kind 10 and the emergency recovery): its `lastTransition()` is read in isolation, with a fixed 100,000-gas cap (a GnoLightClient answers with two storage reads, a few thousand gas; the cap leaves the replacement's frame nearly whole) and only the first 64 bytes of the answer copied; when it reverts, burns its gas or answers anything but exactly two uint64 words, the checkpoint keeps the saved deadline and imposes max(saved deadline, now + the route's quarantine), then voids the old verifier's outcomes and the replacement proceeds (`test_d3_2_recovery_whenTheOldVerifierViewReverts`, `test_d3_2_kind10_whenTheOldVerifierViewIsMalformed`, and for a gas-burning or 4,000-byte view `test_r27_2_kind10_*`, `test_r27_2_recovery_*`). The old client's status probes for recovery eligibility (`isFrozen`, `isExpired`, through `IBCAdminChecks.flag`) are isolated the same way (100,000 gas, one word copied): a failing view answers nothing, and the silence and hold criteria still apply; a kind 6 verifier swap keeps the strict read (a swap of a verifier that cannot answer is spent: replace the route instead). Two paths do not read it: a receive on a route whose quarantine duration and saved deadline are both zero, and the route's first quarantine setting (which arms the route without a checkpoint); a duration applies to transitions accepted after it, a started quarantine keeps its deadline; transitions told apart by number; a duration change reads the route's current client, whichever id names it; the deadline of a started quarantine is checkpointed before any verifier swap (kind 6 op 2) or route replacement (kind 10), so the new client cannot end it early; governance not quarantined | `GnoLightClient._isLiveTransition`, `lastTransition`; `GnoTransferStorage.quarantineUntil`; `GnoICS20Controls.setQuarantine` settles; never checked by IBCAdmin |
| §5.4 envelope, acks, statuses, window W = 64, drain D = 8 (every delivery and `drain()`), duplicates, conflicts | `IBCAdmin.onRecvPacket`, `_deliver`, `_record`, `_drain` |
| §5.4 cancels anywhere: tombstones on arrival of the ranges as given, merged with every stored range they touch; at most 64 stored ranges per epoch, past which a new range merges with the nearest stored one, cancelling the numbers in the gap too; a cancel carries 1 to 16 ranges by its grammar, but the 1024-byte envelope makes 14 the effective maximum (15 ranges take 1,038 bytes: an oversize envelope, spent); a cancel beyond the window is bound to its hash and acked `status 2, redispatch 1`, and a malformed one beyond the window is an error ack | `IBCAdmin._deliver`, `_parseCancel`, `_tombstone`; `IBCAdminStorage.addTombstone` |
| §5.4 epochs: another epoch refused, everything keyed by (epoch, seq) | `IBCAdmin.onRecvPacket`; `IBCAdminStorage.Layout` |
| §5.4 unknown kind / bad params recorded and spent; a decision's parameters must be exactly the canonical `abi.encode` of its tuple (decoded, re-encoded and compared: trailing data, offsets or padding otherwise are spent at recording); a decision failing its checks at execution spent (no code, another code hash, a refused call, failed after-checks, rolled back) | `IBCAdmin._record`, `execute`; `IBCAdminExec.atRecording`, `_codeIs`, `_call`, `_selfStep` |
| no one spends a decision by starving it of gas: recording, refusable calls and self-steps run with fixed budgets and floors | `IBCAdmin._atRecording`; `IBCAdminExec._call`, `_selfStep` |
| §5.4 kind delays: cancel / kind 4 tightening / kind 8 revoke / kind 11 lengthening at recording; unpause 24 h; others 7 d | `IBCAdminExec.atRecording`, `IBCAdmin.execute`, `_delay` |
| §6.6/§7.4 7-day kinds deferred by flags and holds; kind 3 through flags, and under a hold no sooner than its **anchor** plus 21 days. The anchor is the start of the first hold standing at or after the seat change was due (its 7 days passed), even one that began before: the earliest start of the standing hold and of every recorded hold that ended strictly after the due time, so a hold that ended before the change was due never counts, and one nobody observed still does (gno.land anchors at the hold standing at its first deferring `Execute`; both rules avoid an anchor earlier than the ideal one, while history compression and observation timing can make either chain's wait the longer). A hold's end is exclusive: one whose dip grace expires exactly at the due time had ended then and never anchors (`test_kind3_anchor_holdEndingExactlyAtDue_neverCounts`, `testFuzz_anchorAtTheDueBoundary`). The first `execute` that finds a hold standing once the change's ordinary maturity (its 7 days) has passed pins it (`replacementAnchor`, `ReplacementAnchored`); if that moment is before the anchor plus 21 days, it returns without reverting (a revert would undo the pin) and the decision stays pending; at or after that deadline, it pins and executes at once. Later holds never move it: a guardian clearing, waiting out the 24-hour grace and flagging again restarts nothing, and the change lands from the anchor plus 21 days whatever hold stands then (`test_kind3_anchor_clearAndReflagCycles_neverReset`). Examples: recorded on day 0, a hold on days 1 to 3 and another from day 20 → day 41 (`test_kind3_anchor_holdBeforeDueNeverCounts`); a single hold from day 10 → day 31 (`test_kind3_anchor_singleStandingHold`); a hold from day 1, standing when the change is due, → day 22, day 21 of the hold (`test_kind3_throughAHold_noSoonerThanDay21`). The hold history keeps eight holds, a ninth merging the two oldest into one spanning both, marked `merged`: a merged interval may span a gap no hold covered, so it **never** supplies an anchor; a later genuine hold's start (or the standing hold's) is used instead, never earlier than the true anchor (`test_kind3_anchor_compressedHistory_neverEarlier`; the hold fuzz checks every execution against its own, uncompressed record of the holds) | `IBCAdmin.execute`, `_anchor`, `replacementAnchor`; `IBCAdminStorage.hold`, `noteHoldEnd` |
| §7.4 unpause spent under a hold of its object (a route: its flags or refunds flags); kind 2's parameters need a non-empty client id for object 1 (a route) and an empty one for object 2 (IBCAdmin), spent at recording otherwise | `IBCAdminExec._unpause` |
| kind 3 replaces 1 to 4 pairs of distinct, valid seats with distinct resulting keys (spent at recording otherwise), at most 2 guardian seats, never a current key; both key copies follow; a replaced seat loses its recovery approval | `Guardians.checkReplace`; `IBCAdminExec._seats` |
| kind 4 limits, "no field loosens" rule; an older decision maturing later never overwrites a newer setting (kinds 4, 11). Bounds (spent otherwise): a non-zero token, `dayCap` and `refundCap` at most 2^128 − 1 (`LeakyBucket.MAX_CAP`), and `sendMin <= sendMax` when `sendMax` is set. A zero `dayCap` refuses every receive, a zero `maxPerMessage` too, and a zero `refundCap` queues every refund; kind 11's quarantine is at most 365 days | `IBCAdminExec._validLimits`, `_loosens`; `IBCAdminStorage.supersede` |
| kind 5 voucher registration, code-hash pinned, bound to the fork; both the denom and the voucher token must be unregistered (else `exists` at execution); the base denom only in the wire grammar shared with gno.land's ibcgov builder (`isGnoWireDenom`, gno-realms 3852a93), at most 128 bytes: native `[a-z][a-z0-9]{2,15}`; or a GRC20 alias, the literal `gno.land:r`, then at least two `:`-separated segments each matching Gno's `Re_name` `[a-z][a-z0-9]*([_-][a-z0-9]+)*` (single `_` or `-` separators, never leading, trailing or doubled: `gno.land:r:my-org:token.TKN` qualifies), then optionally `.` and a slug of 1 to 32 `[A-Za-z0-9_-]`. Realm-issued coins (`/gno.land/r/...:denom`) are refused; the gno side never sends them. Anything else is spent at recording | `IBCAdminExec._voucher` |
| kind 6 add (custom id, enrolled for kind 10) / migrate a client (quarantine checkpointed and the verifier generation bumped first), code-hash pinned; the verifier usable: for gno.land's chain id, neither frozen nor expired (`IBCAdminChecks.usableClient`, as the emergency recovery checks); the counterparty only in canonical form (gno.land's exact merkle prefix `main`, `/pv/vm:gno.land/r/aib/ibc/core:`, and a client id in [a-z0-9-], 1 to 64 characters; spent at recording otherwise), and a swap keeps the client's counterparty id; a retired client id is never migrated (spent); the emergency recovery's proposal is held to the same counterparty rule. The new Ethereum client id of op 1 follows eureka's router grammar (4 to 128 bytes of its allowed characters, never starting `client-` or `channel-`); the router refuses anything else, which spends the decision at execution. Unlike kind 10, kind 6 is **not** atomic: op 2 checkpoints the quarantine and bumps the verifier generation before calling the router, and a refused router call returns `client` without undoing them, so the decision is spent and outcomes proven before are void anyway. Candidate code that is an EIP-7702 delegation designator is refused even with the pinned hash (kinds 5, 6, 7, 9 and the recovery proposal) | `IBCAdminExec._client`, `_codeIs`; `IBCAdminChecks.usableClient`; `GnoICS20Controls.checkpointQuarantine` |
| kind 7 upgrades (router, transfer app, its two beacons), code-hash pinned, fixed call gas, after-checks (including that every beacon the decision does not name keeps its implementation and owner), a migration call that is empty or carries a selector on the executor's pinned allow-list (`migrationAllowed`: empty in this executor, so every migration call is refused; only a kind 9 hand-over to an executor with its own list extends it), and under any list never an upgrade-setting selector (`upgradeToAndCall`, `multicall`, `upgradeEscrowTo`, `upgradeIBCERC20To`), and on the transfer proxy only code that keeps the controls (`gnoControlsVersion()` at least the running one's, on the implementation before and on the proxy after: never the stock ICS20Transfer or an older fork), rolled back whole on failure | `IBCAdminExec._upgrade`, `migrationAllowed`, `applyUpgrade` |
| kind 8 relayer role only, never a zero account (spent at recording); never ADMIN or any role that upgrades or re-points | `IBCAdminExec.atRecording`/`run` |
| kind 9 hand-over: swap the pinned executor (same bindings), optional migration call, rolled back whole on failure | `IBCAdminExec._handover`, `applyHandover` |
| kind 10 / E12 route replacement `(string oldClientId, string newClientId, uint64 suspectFrom)`: only to a client id kind 6 enrolled, whose verifier is still usable (gno.land's chain id, neither frozen nor expired) immediately before the old route is retired and the epoch switches (spent otherwise, the old route untouched); quarantine checkpointed; retire + freeze the old id, `migrateRoute` (a new incident; the route closes), next epoch over the new id; allowed while the route is closed (an earlier incident carries over untouched; a reopening under way is aborted), only from the route's current client | `IBCAdminExec._route`; `IBCAdminStorage.replaceRoute`; `GnoICS20Controls.migrateRoute` |
| §7.12 suspected compromise interval, per incident: every ack and timeout the retired client processed from block `suspectFrom` on (found by binary search in that client's own processed list), and any it processes later, must be settled by kind 12 before kind 13; the live client's never count; the emergency recovery proposal carries the same field (the reconciliation state machine below) | `GnoICS20Controls.migrateRoute`, `ackHook`; `GnoICS20Reconcile.settleRecords`, `reopenRoute` (`GnoIncidentsPending`) |
| kind 11 route quarantine setting | `IBCAdminExec.atRecording`/`run`; `GnoICS20Controls.setQuarantine` |
| §7.12 proven outcomes: anyone proves a send record's destination outcome through the route's replacement client (`proveOutcome`): the packet authenticated against the record's commitment, gno.land's receipt recomputed (R19: `sha256(0x03 ‖ uint64be(sequence) ‖ sha256(sourceClient) ‖ packet commitment)`, the gno-realms vectors) and compared with the proven one, the ack commitment proven with it; delivered (its receipt, a success ack), refundable (an error ack, or no receipt once the proven time reaches the packet's timeout), or a collision (another receipt at the sequence); final once proven; the replacement client must be active (the route's current client, neither frozen nor expired) when the outcome is proven and when kind 12 uses it: the outcome stores its verifier and the route's verifier generation, and one whose verifier has since frozen, expired or been replaced, or whose route was re-pointed since (even back to the same client), is void (kind 12 refuses it, all or nothing, and a new proof through the active client may replace it); kind 12 checks the verifier again for every outcome it consumes and after its last payment, so a token hook that freezes or swaps it mid-batch rolls the batch back. GnoLightClient has no path that unfreezes it or restores trust in earlier roots | `GnoICS20Evidence.proveOutcome`, `gnoReceipt`; `GnoTransferStorage.activeClient` |
| kind 12 settle: per send record of a retired client id, at most once, all or nothing, with a fixed 6M gas budget and at most eight records (more is spent at recording), each action matching the proven outcome (else the decision is spent): 1 a genuine refund (refundable or collision), `amount` equal to its whole remainder (parked if refused), zero for a refund already paid in full (which only settles the record); 2 reject an owed refund, queued or parked; 3 settled as delivered (2 and 3 need a delivered outcome and nothing refunded yet, and ignore `amount`); 4 forged refund: the record's transport outcome an error ack or a timeout, its proven outcome delivered, `amount` exactly what was already refunded (zero allowed, which only rejects the unpaid remainder; the ADR's "with a refund paid" is relaxed to that), what was paid booked as the loss; 5 a forged receive at an inbound sequence of the retired client, booked as a loss once for exactly the amount the local receive record holds: no destination-outcome proof is involved, so action 5 runs even while the replacement verifier is frozen or expired. Two passes: the first validates and settles every item and owes every action 1 refund its whole remainder, so each one's reservation is restored (a refund a forged success ack hid included); only then does the second pass pay those refunds, each against the batch's complete reservations, in any item order. An ack or timeout of a settled record pays nothing and notifies nobody | `IBCAdminExec.run`; `GnoICS20Reconcile.settleRecords`; `GnoICS20Controls.ackHook` |
| kind 13 names the route's **current** client: a retired alias is refused at execution (`GnoBadRoute`, spent; `test_r26_reopenByARetiredAlias_refused`); it reopens a closed route only when `pendingIncidents` is zero: **no retired client of an unresolved replacement incident has an open send record** (opened by a send, closed by a success ack, a refund paid in full or a settlement) **or an unsettled suspect record**. The live client's records never count, open or not (a refund it owes waits for the reopening, then `claim`), and a late-loss incident needs nothing; otherwise `GnoIncidentsPending` (`openRecords(clientId)` is per client id); every loss not recapitalized becomes an accepted deficit (`GnoDeficitAccepted`, `acceptedDeficit`), 16 tokens in kind 13 and the rest in bounded batches by a permissionless `continueReopen(clientId, n)` (`n`
clamped to 16) (the route stays closed, `routeReopening`, until the last); while the route reopens, no kind 12 runs on a client whose incident is reopening and no loss is booked anywhere on the route (`GnoRouteReopening`); a settlement booking no loss on a client of an already resolved incident still executes; the last batch checks the prerequisites again before the route opens (a retired client's record opened meanwhile keeps it closed, `GnoReopenAborted`); a closed route refuses receives, escrowed sends and claims, while returning vouchers still exit | `GnoICS20Reconcile.reopenRoute`, `continueReopen`; `GnoTransferStorage.openRecord/closeRecord`; `_checkReceiveRoute`, `_sendTransferFromEscrowWithSender`, `_openRoute` |
| E12 route keys, constant-work migration, wire translation | `GnoTransferStorage.routeKey/toRouteDenom/toWireDenom`; `migrateRoute` |
| §7.12 emergency recovery, off unless enabled at deployment; approval ≥ 3 of 4 guardians, cancellation by a guardian majority (≥ 3 of 4, never more than the approval threshold); permanent proposal conditions (the new id's grammar and freshness) checked at approval; eligibility when it opens (see "Emergency recovery" below); an attested client of gno.land's chain id, neither frozen nor expired at approval and at execution; a long public delay of at least 30 days (`MIN_RECOVERY_DELAY`, enforced by the constructor and the deploy script); suspends kinds 3, 6–10 at recording and at execution; while open, blocks receives and escrowed (Ethereum-native) sends at once (`GnoRouteRecovering`), returning-voucher burns staying available; the route stays closed after it | `IBCAdmin` constructor, `approveRecovery/cancelRecovery/executeRecovery`; `IBCAdminRecovery` |
| E4/E11 hand-over of the authorities, deployer roles removed, check list read back. `finishSetup` checks IBCAdmin's and the deployer's roles, never other holders: the AccessManager cannot list a role's members, so **exclusive ownership needs an external audit** of its `RoleGranted` log. Its function list covers the router's governed functions and relaying, the transfer app's governed setters (`setCustomERC20`, beacons, upgrades, `initializeGno`, `setGuardianKeys`, `setLimits`, `setQuarantine`, `unpauseRoute`, `setRecoveryBlock`, `migrateRoute`, `checkpointQuarantine`) and pause/unpause; it does not read the roles of `settleRecords`, `reopenRoute` and `checkpointForReplacement` (unassigned, so the AccessManager's default `ADMIN_ROLE`) or of `sendTransferWithSender` (`DELEGATE_SENDER_ROLE`, granted to nobody); the audit confirms them | `script/DeployGnoIBC.s.sol`; `IBCAdmin.finishSetup`; `IBCAdminSetupCheck` |
| §5.4/§7.2/§9 **inactive launch**: the ugnot route is deployed with zero limits (no receive, no escrowed send: no exposure) and stays so until Ethereum has recorded gno.land's first decision; the **activation** is a kind 4 from gno.land (a loosening: its 7 days) setting the activation limits derived from the expected lock: day cap min(100,000 GNOT, lock/10), max per message min(25,000 GNOT, day cap), refund cap the day cap; `GNOT_*` overrides only lower them. The deploy script writes the activating kind 4's parameters (`activationKind4Params`) into the deployment file and reads the installed limits back. `LAUNCH_ACTIVE=true` (test networks only, refused on mainnet) installs the activation limits at launch instead; the e2e and Sepolia scripts use it; quarantine 7 d | `DeployGnoIBC._params`, `_launchLimits`, `_deploy` (`InactiveLaunchTest`, `LaunchParamsTest`) |

## Reconciliation state machine

This is the specification the controls implement for route closure, reconciliation (kind 12) and reopening
(kind 13), across any number of incidents. `GnoTransferStorage` holds the state; `GnoICS20Controls.migrateRoute`,
`ackHook`, `GnoICS20Reconcile.settleRecords`, `reopenRoute` and `continueReopen` are
the transitions.

### State

- **Client generation.** Every client id a route has had is one generation: the route's current (live) client, or
  a retired one. Per client id: the list of the blocks at which its acks and timeouts were processed (append-only,
  in order; a send record keeps its index in it), its **open-record count** (records opened by a send
  and not yet closed by a success ack, a refund paid in full or a settlement), and, once retired, the **incident**
  covering it, the first suspect index `suspectStart` and its **suspect count**.
- **Incident.** A closure of the route: `{kind, status, client, suspectFrom}`.
  - kind *replacement* (kind 10 or the emergency recovery): covers exactly the client id it retired. Its suspect
    range is that client's processed list from the first entry at or after block `suspectFrom` to the end, frozen
    at closure, plus every ack or timeout processed on that client later (a retired client cannot normally process
    any: it is frozen).
  - kind *late loss*: a loss kind 12 booked while the route was open. It covers no records.
  - status *open* → *reopening* → *resolved*, derived from two bounds: incidents below `resolvedUpTo` are resolved,
    those from it below `reopenUpTo` reopening, the rest open. Incidents are appended.
- **Route.** `closed`, `reopening` and the deficit cursor; `pendingIncidents`, the unresolved replacement incidents
  whose client still has an open or unsettled suspect record (kept by every change of those counts); the losses and
  accepted deficits per token, and every loss's canonical identity (client id, sequence, direction).

No transition walks the incidents: kind 13 reads `pendingIncidents`, and reopening, resolving and aborting move the
bounds (constant work whatever the number of incidents).

### Invariants

1. A route is open (`closed == false`) only if every incident on it is resolved.
2. A send record is open exactly while its commitment is outstanding (no ack or timeout processed, not settled) or a
   refund is owed (a refund outcome not paid in full, not settled). A client id's open-record count is the number of
   such records, and once a replacement retires it, its suspect count is the number of its unsettled records processed
   at or after the replacement's `suspectFrom`. An incident is resolved only once its client has neither. The invariant
   campaign derives all of this from its own ghost, never from the records' flags or the stored counters: the
   transport history (each packet's ack or timeout and the block it was processed in), the settlements governance
   executed, and the incident boundaries (each replacement's retired client and `suspectFrom`). It also executes kind
   13 while the ghost says work remains (`prematureReopen`: it must be spent and the route stay closed), and relays a
   settled record's late ack or timeout, with the retired client's freeze defeated for that one call (`lateOnSettled`:
   ignored, nothing paid, the record unchanged).
3. Acks and timeouts on the live client never count against any incident.
4. Every send record is settled at most once, and a refund is never paid twice (`refunded <= amount`).
4a. A send record is bound to its packet: its token, sender, amount and commitment are those of the packet the
    router committed (the packet's own data), never changed after the send. The campaign derives the packet's
    metadata independently from its own send inputs and compares it with the decoded payload: the source client
    the send named, the canonical sender (`Strings.toHexString`, lowercase), the full wire denom (a native token's
    address; gno.land's voucher `transfer/<that client>/ugnot`), the receiver and the amount. Corruption probes
    that substitute the sender or the denom, with the record's commitment moved to match, fail it at once
    (`test_r22_1_senderSubstituted_failsAtOnce`, `test_r22_1_denomSubstituted_failsAtOnce`).
4b. Payments conserve tokens (for supported tokens): every sender holds what it had, less what it sent, plus exactly the refunds its
    records show; the escrow holds what was sent, less every refund and every receive; receivers hold exactly what
    was received; a voucher's supply moves only by receives, returns and refunds. An undelivered packet's sender
    ends refunded its packet's full amount, or the remainder stays reserved.
    Every party is checked on its own, never pooled: alice, the contract sender that re-enters, the sender adapter
    (less what it forwarded) and the adapter's owner (exactly what was forwarded), each from what the campaign minted
    to it per (sender, token), what it sent and the refunds of its own records; only bob sends the voucher. Probes
    that move a paid refund to another party, with every total unchanged, fail it at once
    (`test_r23_reentrantRefundRedirected_failsAtOnce`, `test_r23_adapterRefundRedirectedToOwner_failsAtOnce`).
4d. **One terminal notification per packet, of the right kind.** Each contract sender's packet (the adapter's and
    the re-entrant sender's) is told its outcome at most once, with a kind its outcomes allow (the transport's as
    relayed, or the settlement's: action 1 a refund, 2 to 4 a success), and a refund only once paid in full: each
    sender keeps its own per-packet callback history (count and kinds), and the oracle checks it independently of
    the controls' notification bookkeeping. The history is snapshotted when the packet is settled: a callback
    delivered before the settlement stays the only one allowed, and with none only the settlement's terminal kind may
    follow (`staleSuccessRetry`: a refused forged success, then action 1, then the stale success retried, refused;
    `test_r28_staleSuccessAfterRefund_refused_andProbe`). `successRetry` drives a refused success retried before settlement (once,
    a second retry refused), then reconciled; a wrong-kind probe (a paid refund announced as a success) fails at once
    (`test_r27_4_successRetry_andWrongKind`). The campaign forces both contradictory directions (a
    delivered forged success then an action 1 refund, `noticeSuccessThenRefund`; a delivered refund notification then
    an action 4, `noticeRefundThenSuccess`), trying both notification paths after the settlement, and a refund paid
    late after an unprepared reopening (`delayedPayNoticeOnce`: delivered once, then refused). A corruption probe that
    delivers a second callback fails it at once (`test_r26_6_secondTerminalCallback_failsAtOnce`).
4c. Kind 12's actions agree with the proven outcomes (a refund only for a packet not delivered, a delivered
    settlement only for one delivered), and the losses booked equal the forged payouts as amounts.
5. Escrow per route and token is at least the reservation (owed refunds and outstanding sends, §7.12), for tokens
   with the supported semantics ("Supported tokens" below): a balance change outside the bridge (an issuer's seizure,
   a negative rebase) is outside this guarantee.

   **Every success that may hide a refund is held** (`held`, reserved at its whole remainder):
   - every unsettled success a retired client processed in its suspected compromise interval, reserved by the
     incident's preparation (`prepareIncident(clientId, n)`: permissionless, `n` records per call as the caller
     chooses, no fixed clamp, returning the records **remaining**, not processed; over the client's processed
     list from `suspectStart`);
   - a success a retired client processes later, held at once by the ack hook;
   - a success proven owed (refundable or a collision), held by `proveOutcome`.

   **Before any kind 12 payment, every unsettled suspect success of the route is reserved.** Kind 12 pays no refund
   while any incident of the route is unprepared (the refund stays parked). This holds whatever the order of
   proofs and decisions. Outside kind 12 a closed route pays nothing: no claim, and acks do not pay.

   **Settlement freezes the evidence.** `proveOutcome` and `voidOutcome` refuse a settled record (`GnoBadProof`), so
   no later proof, even a valid non-receipt after the settling proof went stale, can recreate a hold, change a
   reservation, or replace the proven ack its notifications use (`test_d6r1_settledRecord_evidenceFrozen`).

   **A hold is released only by the kind 12 that settles the record**, with an outcome still valid at execution.
   No proof releases it, not even one of delivery, which may later go void. `voidOutcome` clears an outcome its
   verifier no longer vouches for, so that it can be proven again, and keeps the hold. A batch that settles a
   delivered record and pays a sibling still works: its first pass settles every item (releasing the delivered
   one), its second pays.

   Successes processed before the suspect interval are trusted (the replacement confirms the history up to it)
   and are not held; one proven owed is held from its proof.

   The campaign drives:
   - `voidAndReprove`: three hidden refunds proven, the verifier migrated, two voided, one re-proven and settled;
     it must not pay;
   - `deliveredVoidSibling`: a delivered success and a hidden refund, either proven first, the verifier replaced,
     the hidden refund settled before the delivered one is proven again; it must not pay;
   - `prepareStep` and `proveAndPay`: preparation, proofs and payments interleaved arbitrarily.

   The only
   permitted shortfall is the one reconciliation recognizes: the refunds kind 12 owes again for packets a forged
   success ack released, whose backing the compromise consumed. That allowance belongs to those very refunds and
   only while they are unpaid. Every other record's reservation is backed in full at all times, so a payment of one
   refund never takes another's backing, and no receive or payment ever increases the shortfall.
   The invariant campaign checks this from its own ghost. The ghost keeps its own processed list per client and its
   own preparation cursor, so every partial batch's holds are expected as they happen (and the records left are
   checked against the cursor). It holds a success when a batch visited it, when it was processed while retired, or
   when the ghost proved it owed, and releases it only at settlement. Expected reservations come from the ghost's
   transport history and governance's settlements, never from the record's outcome or payment state. The record's
   outcome must agree with that history: pending exactly when never processed, a success exactly when the relay was
   one. A corruption probe that sets an outstanding record to `Success` and drops its reservation fails at once
   (`test_r21_2_outcomeCorruption_failsAtOnce`). It asserts that no kind 12
   refund is paid before every incident of the route is prepared. It marks a held success eligible for the
   shortfall allowance when it becomes held, and bounds the allowance by their unpaid part and by what was uncovered at the previous step (lowered at
   every step, never raised but by a new hold). It asserts that the escrow covers every reservation but the eligible
   refunds' unpaid part. It also checks every payment's own postcondition: a record paid since the previous step
   left every other record's reservation backed, other refunds owed again included. Only the paid record may stay
   short. `twinEligibleRefunds` drives that: two such refunds unpaid against 150 of backing, one retried.
   The ghost classifies each send as a voucher burn or a native escrow from its own token origin and the
   authenticated packet's denom. It requires the record's `burned` flag to match, and computes reservations from
   that classification. A corruption probe that flips one record's flag fails at once
   (`test_r18_2_burnedFlagCorruption_failsAtOnce`). `twinHiddenInitial` settles two hidden refunds together, in
   either order, and in separate decisions. `partialBacking` drives the case: a hidden refund of 100 owed again against 50 left, then
   receives on the new live client, which must be refused. A new outstanding send of 100 follows, then a retry of
   the older refund, which must not take the new send's backing. Removing either the receive path's or the payment's
   reservation guard fails the campaign.
6. When a route opens, every token's losses equal its accepted deficit.
7. While a route is reopening, its losses do not change. Reconciliation is sealed: no kind 12 on a client whose
   incident is reopening, and no loss booked anywhere on the route. The invariant campaign snapshots every token's
   losses only when a kind 13 starts a new reopening (right after it executes, never at any other moment). It
   compares them after every call, and between the steps of every composite call, while that reopening runs.
   `lossResolvedIncidentDuringReopening` books a loss on a record of an incident already resolved while another
   reopens, so only the route-wide seal refuses it; removing that seal fails the campaign. Continuation batches of 1
   to 8 deficits over 33 loss tokens make several continuations that are not the last.

### Transitions

| Event | Precondition | Effect |
|---|---|---|
| replacement (kind 10, emergency recovery) | the old id is the route's current client; the new id fresh (its own route key, if it had one, is abandoned: the new client aliases the old route, whose flags, limits and quarantine govern from then on; flags set under the candidate's own id do not carry over, so operators flag the existing route) | a new *replacement* incident covering the old id (suspect range from `suspectFrom`); the route closes; a reopening under way is aborted (its incidents back to *open*); earlier incidents, their records, reservations and counters untouched. Allowed while the route is closed |
| ack or timeout | a record of the client | appended to the client's processed list; counted as suspect only if the client is retired |
| delivery or drain of a governance decision | the transfer app not busy (a delivery from inside a hook reverts whole with no data, so the router writes nothing and the packet is relayed again later; `drain()` records nothing) | the decision recorded; one acting at recording (kind 4 or 11 tightening) applies |
| kind 12 on a retired client's records | its incident not *reopening*; the outcome proven by the active verifier | the record settled once; its client's open and suspect counts follow |
| kind 12 booking a loss | the route not reopening | the loss recorded; if the route was open, a *late-loss* incident opens and the route closes |
| kind 13 | the route closed and not reopening; `pendingIncidents` zero (every replacement's client with no open and no suspect record; a late loss needs none) | `reopenUpTo` moves to the end: unresolved incidents become *reopening*; deficits accepted in batches (`continueReopen`) |
| last deficit batch | — | `pendingIncidents` checked again (defensive: with the reopening incidents sealed, their clients frozen and no backfill, no record can open meanwhile): zero → `resolvedUpTo` moves to `reopenUpTo` (*resolved*), the route opens; otherwise the reopening aborts (`reopenUpTo` back: incidents *open*, the route stays closed) |

Each client id is retired once, so its suspect range never overlaps another incident's and a record reconciled by
one incident is never counted by another; nothing is counted on the live client.

### Operating rules and accepted residuals

- **Choosing `suspectFrom`.** A replacement's `suspectFrom` (kind 10, the emergency recovery) must cover the
  **earliest potentially compromised operation** of the retired client: a client update, or a membership or
  non-membership verification (an ack's or timeout's proof), under every affected verifier implementation version.
  It defaults to **0**, which counts every ack and timeout the retired client ever processed (the range is clamped to
  the client's activation, because its processed list starts there). A later boundary needs both: a safe history
  prefix (every consensus state the client retained before it is genuine), and evidence that no affected verifier
  version verified any proof before it. It is then the earliest of those operations' blocks, never the first
  potentially forged root's alone: a verifier defect can accept a forged ack against a genuine root. Genuine roots
  alone, older or newer, never justify excluding earlier proof operations. Choosing it later than the facts support
  leaves forged successes unreserved and outside reconciliation.
- **Refund liveness on a closed route.** This is a deliberate exception to refund liveness. A closed route pays
  no refund outside kind 12 until it reopens: no claim, and acks and timeouts do not pay. Those refunds stay owed
  and their escrow stays reserved, so nothing else can spend it. Getting them paid depends on governed, bounded
  reconciliation: kind 12 settles them (seven-day delay, at most `MAX_SETTLE_ITEMS` per decision) and kind 13
  reopens the route, after which a parked refund is claimed (`claimParked`).
- **Parked refunds when escrow is short.** A genuine refund that kind 12 settles (action 1) is paid only from free
  escrow: what remains after every other reservation of the route's token. When free escrow is short, the payment
  is refused and the refund **parks**. It stays owed and fully reserved; it does not fail, and it does not revert
  the batch. Its record is settled and therefore closed, so it never blocks kind 13. The accepted-deficit
  reopening completes, and the refund is paid by `claimParked` once the backing returns
  (`test_parkedShortfallRefunds_reopeningCompletes`, `test_r17_1_twinHiddenRefunds_reservedBeforeAnyPayment`).
- **Settlements are final.** A kind 12 settlement is final once it executes. Before that, it waits its seven-day
  delay: guardians can hold it, and a compromise discovered meanwhile voids its proofs (the quarantine checkpoint
  of a verifier swap or replacement changes the verifier generation, and execution requires each record's outcome
  proven by the active verifier). If the verifier that proved a settled outcome is found compromised only after
  execution, the settlement is not reopened: a settled record refuses every later kind 12. A genuine refund it
  denied (settled as delivered, actions 2 and 3) is an **accepted residual**: the ADR reconciles each record once
  (§7.12) and specifies no path for it. Its credit-by-vote rule concerns destination claims backed by a receipt with
  a successful or asynchronous acknowledgement, not refunds denied by a final Ethereum settlement. **No compensation
  path exists on Ethereum.** No kind pays from escrow or credits a sender outside kind 12, and kind 12 cannot book a
  loss against a settled record. This document's operating policy is to compensate such a refund outside the
  bridge; a governed path (it would need a kind 7 upgrade of the transfer app) is a proposed extension, not part of
  the design.
- **Cross-chain reconciliation precondition (receive entitlements on gno.land).** A compromised Ethereum-side
  verifier of gno.land is not the only risk: gno.land's suspect receive entitlements (vouchers or releases it paid
  for packets Ethereum supposedly sent) must be reconciled too. Before kind 13 reopens a route, and before the
  containment is cleared, operators enumerate gno.land's suspect receive entitlements for the incident and
  authenticate each against Ethereum's permanently retained `sendRecord(clientId, sequence)` commitment, read from
  an **independently authenticated finalized state** (an independently trusted node, never the possibly compromised
  light client or a single third-party RPC), with `eth_call` and `eth_getProof` pinned to that finalized block,
  never "latest". A matching commitment is genuine. A forgery is conclusive in any of three ways, all read from that finalized
  state:
  - a `sendRecord` at that (client id, sequence) that holds a **different** packet's commitment: forged at once;
  - **no** `sendRecord` there, while eureka's `prevSequenceSends[sourceClient]` (in `IBCStoreUpgradeable`'s ERC-7201
    storage: the last allocated sequence) satisfies `prevSequenceSends ≥ seq`, so no send can ever take that
    sequence: forged at once;
  - no `sendRecord` there once the finalized timestamp has reached the packet's timeout (a forged packet may carry
    a timeout years ahead, so this path alone is not enough).

  The router's sequence has no public getter in eureka v3.0.2 (`nextSequenceSend` is internal): read it as a
  storage proof (`eth_getProof` on the router proxy at the pinned finalized block) of `IBCStoreStorage.prevSequenceSends[sourceClient]`.
  The namespace is at slot `0x1260944489272988d9df285149b5aa1b0f48f2136d6f416159f840a3e0747600` (ERC-7201
  `ibc.storage.IBCStore`) and the mapping is its second field, so the word is at
  `keccak256(bytes(sourceClient) ‖ uint256(0x1260944489272988d9df285149b5aa1b0f48f2136d6f416159f840a3e0747601))`. It
  holds the last sequence assigned (the next is that plus one) and counts every app's packets on that client id,
  IBCAdmin's notices included. Until one of the three applies, the entitlement stays unresolved and containment stays
  in place. Every forged entitlement is voided or settled on
  gno.land first.
  Ethereum's kind 13 checks only its own incident counters and cannot see these entitlements; when the evidence is
  unavailable, the route stays closed.
- **Cross-chain loss ownership: the payout chain is authoritative.** A loss is identified by its packet (the
  sending chain's client id and sequence) and its token. Every loss is a payout on exactly one chain, and it is
  booked there with that chain's own machinery: on Ethereum, kind 12 action 4 (a forged refund paid here) or action 5
  (a forged receive paid here); on gno.land, its void and settlement paths. Its remedies (recapitalization,
  reduction, accepted deficit) act on that chain. A record on the other chain of the same (packet, token) is a
  **mirror**: it is resolved only by an accepted deficit (kind 13 here), never recapitalized or reduced. Monitoring
  counts each loss once, at the payout chain's open balance; mirrors contribute nothing.
- **`claimParked` and the meter.** `claimParked(clientId, sequence, gasBudget)` retries a parked refund (else
  `GnoNotParked`) on an open route with no refunds hold (`GnoRouteClosed`, `GnoRefundsHeld`). An ordinary parked
  refund (from an ack, a timeout or a claim) is metered: it pays what the refund meter allows now. A refund kind 12
  settled (action 1) retries its whole remainder outside the meter, a governed decision having fixed it. A payment
  that fails reverts the call (`GnoRefundFailed`), leaving the refund parked and the meter untouched.
- **Supported tokens.** The escrow, reservation and conservation guarantees (invariants 4b and 5, the reservation
  rule) hold only for tokens with these semantics: a transfer moves exactly the amount asked, to the named account;
  `balanceOf` is truthful; balances change only by transfers the holder makes or receives (no rebasing, positive
  or negative; no fee on transfer; no balance taken by the issuer). The code checks one of these at every send:
  eureka's `_transferFrom` (and its permit2 variant) compares the escrow's balance before and after and refuses
  any difference from the amount (`ICS20UnexpectedERC20Balance`), so fee-on-transfer tokens cannot be sent. Nothing
  checks it at release, and nothing can see a balance change made outside the bridge. **Before enrolling a token**
  (its first kind 4 limits, which escrowed sends require), governance must therefore establish that it has these
  semantics: no fee-on-transfer, no rebasing, no hooks that move other balances, a truthful `balanceOf`, and the
  issuer's powers to pause, blacklist, seize or burn balances and to upgrade the token. Such powers are **trusted**:
  an issuer that seizes or burns escrow, a rebase that lowers it, or an upgrade that changes these semantics creates
  a shortfall outside the one reconciliation recognizes, and the invariants do not hold for that token. A token
  that pauses or blacklists only makes refunds park (`claimParked` retries them). gno.land vouchers are the bridge's
  own code (kind 5, code-hash pinned).
- **Recovery disabled means stranded backing after a channel loss.** With recovery disabled (the default), an
  ordinary channel loss (the epoch client frozen or expired, governance unable to reach Ethereum) leaves no path to
  a new route unless a suitable repair was already recorded before the loss: a kind 6 op 2 migrating the epoch
  client to a healthy verifier (enough when the old history is trusted: `migrateClient` needs the old client to
  exist, not to be active), or a kind 6 client and a kind 10. Otherwise the frozen or expired client refuses every
  proof, so new proof-based processing on the route stops (acks, timeouts, receives, redemptions); refunds already
  owed, queued or parked, stay claimable (`claim`, `claimParked`) subject to their ordinary gates, backing and meter.
  The rest of the escrow's backing can become permanently stranded. A fresh deployment cannot recover it.
- **Emergency recovery.** Configured once, at deployment (`RecoveryConfig`, `recoveryConfig()`), and fixed: no
  governed decision enables, disables or retunes it later (IBCAdmin is immutable). **Whether to enable it is a
  pre-deployment decision**, taken with the guardian set the deployment installs; a deployment with recovery
  disabled stays without it. `delay` (0
  disables recovery; otherwise at least 30 days, `MIN_RECOVERY_DELAY`; launch value 0 unless `RECOVERY_DELAY` is set),
  `threshold` (approvals, `RECOVERY_THRESHOLD`, launch 3, 3 or 4 when recovery is enabled), `cancelThreshold` (cancel
  votes, `RECOVERY_CANCEL_THRESHOLD`, launch 3; when enabled at least 3 and **at most `threshold`**, so the guardians
  who can open a proposal can always close it, as long as they still hold their seats; the constructor and the deploy script refuse anything else,
  `test_m1_cancelThreshold_atMostTheApprovalThreshold`), `silence` (launch 30 days,
  `RECOVERY_SILENCE`; 0 disables that criterion) and `holdPeriod` (launch 14 days, `RECOVERY_HOLD_PERIOD`; 0 disables
  it). A proposal (`RecoveryProposal`) names `newClientId`, `counterpartyClientId`, `merklePrefix` (canonical:
  gno.land's exact prefix), `lightClient`, `codeHash` and `suspectFrom`.
  - **Approval** (`approveRecovery`, a guardian seat, after `finishSetup` and after gno.land has bound, while no
    proposal is open): the proposal's
    client must be code with that hash (not an EIP-7702 designator), follow gno.land's chain id, and be neither frozen
    nor expired, every status view answering exactly. Every permanent condition execution needs is checked here,
    before the proposal can open: `newClientId` is a valid custom router id (4 to 128 bytes of the router's grammar,
    never `client-` or `channel-`) and unknown to the router, which also makes it a fresh route for the transfer app
    (every id the transfer app knows, a route key, an alias, a retired id or an escrow's, was a router client); a
    proposal naming, say, `bad` is refused (`test_m1_permanentlyInvalidIds_refusedAtApproval`).
    With the authority-changing kinds suspended while it is open, these stay true until execution. Each seat
    approves one proposal (its hash); a replaced seat loses its approval.
  - **Launch invariant: Ethereum stays at epoch 1 until gno.land binds.** gno.land binds by sending IBCAdmin its first
    decision. Until IBCAdmin has recorded one (`lastSeq` non-zero in epoch 1), approval is refused
    (`RecoveryNotEligible`, `test_m2_recoveryRefusedBeforeTheFirstDecision`): a recovery then would advance Ethereum
    to epoch 2 while gno.land binds at epoch 1, and every dispatch would be refused with nothing to repair it. Kind 10
    needs no such gate: it can only come from gno.land, after the binding.
  - **Opening**, checked on each approval (so a guardian calls `approveRecovery` again when eligibility arrives later):
    at least `threshold` seats approve this proposal, and the route is **eligible**, which is any of: the epoch's
    client answers `isFrozen()` or `isExpired()` true (an exact answer: a client answering neither opens nothing by
    status); `silence` is non-zero and at least `silence` has passed since `lastRecordTime`, which every recorded
    decision and every epoch opening resets (launch: the constructor's time); `holdPeriod` is non-zero and a hold on
    IBCAdmin has stood for at least `holdPeriod` since it started. Opening sets `openedAt`, blocks the route's receives
    and escrowed sends, and suspends kinds 3, 6–10.
  - **Before execution**, a guardian withdraws its approval (before opening) or votes to cancel (after);
    `cancelThreshold` votes close the proposal and unblock the route.
  - **Execution** (`executeRecovery`, permissionless): at least `delay` after `openedAt`, and the proposal's client
    still usable (as at approval). Eligibility is **not** checked again. Any failure reverts the whole call: the
    proposal stays open and the route stays blocked, so anyone retries once the cause is gone (a client that froze
    or expired meanwhile never recovers), or the guardians cancel it. **The cancellation quorum must stay
    available**: an open proposal that can no longer execute is closed only by `cancelThreshold` guardian votes, and
    guardian replacement (kind 3) is suspended while it is open.
  - **Keeping the candidate fresh.** The proposal's verifier must still be neither frozen nor expired when the delay
    (30 days or more) ends, longer than a trusting period (14 days at launch). It is not a router client until
    execution, so the ordinary client-update relaying does not reach it: an operator relays updates **directly to
    the candidate's address** (`updateClient` on the light client) at least daily throughout the delay, and monitors
    its latest consensus time against its trusting period, alerting well before expiry. If it expires anyway, the
    guardians cancel the proposal and propose a fresh, attested client. It adds the client under its new id,
    checkpoints the quarantine, migrates the route (a new incident; the route closes), freezes the old id and opens the
    next epoch, whose notice it sends.
- **Trust in gno.land's Ethereum verifier (reverse direction).** Governance depends on gno.land's approved local
  client of Ethereum as well as on Ethereum's client of gno.land. These are accepted residuals, as on gno.land
  (gno-realms ADR 0004, "A compromised notice verifier, or a poisoned intermediate client, is not recoverable
  inside ibcgov"):
  - **A compromised approved gno-side Ethereum verifier can move gno.land's governance epoch wrongly.** It can
    authenticate a premature notice, for instance for an expected A→B whose kind 10 Ethereum later cancels or spends.
    gno.land then switches to B and retires A, while Ethereum stays at A; Ethereum-bound dispatches go over B and
    IBCAdmin refuses them. No decision undoes the switch, and resending notices cannot repair it. A premature notice
    naming the epoch and client a kind 10 Ethereum already recorded costs nothing (Ethereum executes it and its
    genuine notice is answered as a duplicate). The only repair is Ethereum's **emergency recovery, if enabled**, to a
    fresh router client that gno.land records as expected from where the forged switch left it: its epoch must be
    above gno.land's and within 64 of it, so if gno.land was moved ahead, Ethereum needs as many recoveries (30 days
    each) as it takes to pass gno.land's epoch. **With recovery disabled, the governance channel can be lost for
    good.** Only Ethereum-bound governance is lost; gno.land's own governance does not depend on the epoch.
  - **A poisoned client that gno.land keeps Active blocks catch-up.** A gno-side local client kept Active by forged
    updates at every prefix endpoint within 64 steps blocks a catch-up past 64, since gno.land's in-place recovery
    needs a Frozen or Expired client. It is repaired only once it is frozen by misbehaviour (when conflicting valid
    updates exist) or expires because its updates stop, **and** an honest, independently authenticated substitute
    client stands ahead of it (the in-place recovery copies the substitute's state over the subject); then it is
    recovered in place and the notice resent through it. Freezing alone does not provide that substitute: if a
    verifier defect left every usable endpoint with a poisoned head beyond canonical Ethereum history and no honest
    substitute exists ahead of it, the recovery stays unavailable, resends still go to those client ids, and a
    notice more than 64 epochs ahead cannot bypass them: catch-up past that client can fail for good. This is part
    of the poisoned-client residual.


## Execution of decisions, per kind

`IBCAdmin.execute` checks, before anything runs: the decision pending, not suspended by an open recovery, not
deferred by flags or holds, mature, the transfer app not busy (`Busy`: a transfer-app entry point is running, so a
token or sender hook called in), the executor's code the pinned one (`ForeignExec`), a refund-paying kind 12 not under
its route's refunds hold (`Deferred`), and enough gas left for the kind's frame: at least floor(frame × 64 / 63) +
60,000 at that point, after the checks before it (`CallStarved`). The frame budgets in the table below are therefore
not sufficient transaction gas limits. Each of these execution checks reverts and leaves the decision **pending**: calling `execute` again with enough
gas retries it. One exception does not revert: a seat change (kind 3) whose first held execution pins its anchor
returns, pending, before the anchor plus 21 days (a revert would undo the pin; see the kind 3 rule above). Recording starvation is different. Recording has its own 1M frame (`RECORD_GAS`) and floor,
1M × 64 / 63 + 10,000; with less gas the delivery reverts `ExecutionStarved` and the recording is rolled back, but
the router keeps the packet's receipt and commits an error ack, so relaying the same packet again is a no-op. An
envelope that was never recorded is retried by a source-side redispatch, in a fresh packet from gno.land; work
already buffered on Ethereum is recorded by `drain()` called with enough gas. A tombstoned pending decision is the exception: `execute` cancels it
(`CANCELLED`, its parameters deleted, `DecisionCancelled`) and returns.

**A pending decision has no execution expiry.** `execute` checks a minimum maturity and no maximum age, so a recorded
decision stays executable indefinitely until it is cancelled (kind 1), spent, or abandoned by an epoch switch (every
decision is keyed by its epoch). This is distinct from the ADR's 14-day deadline on gno.land **proposals** (before
a decision is ever dispatched): nothing on Ethereum ages a recorded decision out. Then the
executor runs in a frame of its own with the kind's fixed gas (`IBCAdminStorage.execGas`): a reason returned, a call
refused, or anything reverting inside it (its own gas included) **spends** the decision, which never runs again.

| Kind | Frame gas | External calls at execution | Deterministic failures (all spent) | Test |
|---|---|---|---|---|
| 1 cancel | — | none (tombstones on arrival; `execute` of a tombstoned decision cancels it) | — | `IBCAdminDelivery.t.sol` |
| 2 unpause | 1.5M | transfer `routeHold`, `refundsHold`, `unpauseRoute` | `hold`; a revert | `test_r3_unpauseSpentUnderARefundsHold` |
| 3 seats | 1.5M | transfer `setGuardianKeys` | `current key`, `params`; a revert | `test_r6_5_deterministicFailures_spendEveryKind` |
| 4 limits | 1.5M | transfer `setLimits` | `params`, `superseded`; a revert | same |
| 5 voucher | 1.5M | voucher `ics20()`; transfer `setCustomERC20` (refusable) | `codehash`, `denom`, `voucher`, `exists`; a revert | same |
| 6 client | 2.5M | router `getCounterparty`, `addClient`/`migrateClient` (refusable), `getClient`; transfer `isRetired`, `checkpointQuarantine` | `codehash`, `counterparty`, `retired`, `client`; a revert (a client that does not exist yet) | same |
| 7 upgrade | 3.5M | transfer beacon getters; self-step: `upgradeToAndCall` (2M), version probes, authority, binding and beacon reads | `codehash`, `params`, `migration call`, `nested upgrade`, `upgrade`; a revert | same; `test_r5_2…`, `test_r4_1…` |
| 8 role | 1.5M | AccessManager `grantRole`/`revokeRole` | `role` (validated at recording too); a revert | — (no failure reachable after recording) |
| 9 hand-over | 3.5M | executor `bindings()`; self-step: the migration call (2M) | `codehash`, `bindings`, `migration`; a revert | `test_r6_5_deterministicFailures_spendEveryKind` |
| 10 route | 2.5M | transfer `checkpointForReplacement` (the old verifier's view capped), `migrateRoute` (refusable); router `migrateClient` (freeze) | `client`, `route`; a revert | same |
| 11 settings | 1.5M | transfer `setQuarantine` | `params`, `superseded`; a revert | same |
| 12 settle | 7M | transfer `settleRecords` (6M, refusable): proofs' verifier, token and escrow calls (each payment 200,000 gas) | `settle`; a revert | same; `test_r6_3…` |
| 13 reopen | 2.5M | transfer `reopenRoute` (refusable) | `route`; a revert | same |

## Divergences from the ADR

The amended ADR (2026-10-16) now specifies the port `ibcgov`, the 1024-byte envelope, custom client ids, the ack of
a cancel beyond the window, commitment-only send records, and kinds 12 and 13. What remains:

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
5. *Historical, now in the ADR:* kind 10 is also suspended while an emergency recovery is open (the amended ADR
   lists it too).
6. **Limits are required for escrowed sends** of an Ethereum-native token, and a token's first limits setting always
   waits 7 days.
7. **Undecodable parameters are spent at recording** (all kinds are decoded then).
8. **Kind 7 cannot read a UUPS proxy's implementation slot on chain**: after-checks read authority and bindings, and
   the migration call is empty unless a kind 9 hand-over installed an executor whose pinned allow-list admits its
   selector (never an upgrade-setting one). Beacons are checked exactly, the ones not named included.
9. **Kind 12 pays refunds outside the refund meter** (a governed decision) and only for records of a retired client
   id.
10. **No recapitalization decision exists yet** on Ethereum: kind 13 accepts every recorded loss as a deficit.
11. **Incidents per client generation**: each route closure is an incident (the reconciliation state machine above);
    a replacement may follow another before its reconciliation completes, and each suspect range is its retired
    client's own processed list, so it never overlaps another incident's. A `suspectFrom` in the future counts
    nothing.
12. **Seat generations**: a flag stores, besides its block, time and key, the generation of the key that set it, so
    a key removed and restored in the same block cannot revive its earlier flags.
13. *Historical, now in the ADR:* **a proven non-receipt waits for the packet's timeout.** The original ADR counted a non-receipt as refundable because the
    destination's old client is frozen; Ethereum cannot prove that freeze, so `proveOutcome` takes a non-receipt
    only at a proof height whose destination time (the replacement client's, returned with the proof) reaches the
    packet's timeout (eureka caps timeouts at one day), as the amended §5.4 has it.
14. **A reconciliation refund's synthesized notification is `onTimeoutPacket`** (the packet was not delivered),
    delivered by `notifySettled` only when the settlement replaces another transport outcome, or none, and no
    transport callback was delivered. When action 1 keeps an existing refund outcome, its original notification
    survives (an error-ack refund still announces `onAckPacket(false, …)`), and a settlement only marks it due, which
    `retryNotification` delivers. A transport callback already delivered is final; the settlement is then reported
    by `GnoSettled` alone.
15. **Receives record their amount in 96 bits**: a receive above 2^96 - 1 is refused (an error ack), so kind 12
    action 5 can check the amount from one slot. This packet cap is separate from the governed limits, which may be
    set higher (`dayCap` up to 2^128 − 1): the lower of the two binds.
16. **Outstanding sends reserve their escrow**: a redemption from gno.land cannot release escrow that an outstanding
    send may have to refund; an honest redemption is covered by the delivered sends' escrow. Sends are capped at
    2^96 - 1, as receives.
17. **A loss found after a route reopened closes it again** (`GnoRouteClosedForLoss`) until a new kind 13 accepts it;
    that reopening does not wait for the live client's open records.
18. **Kind 7 on the transfer proxy checks the fork's modules**: its three modules (controls, reconciliation,
    evidence) must be code answering its controls version, and the proxy must answer that version for all four
    probes (the fork and its three modules) after the upgrade.
19. **Vacancies are not supported**: kind 3 never sets a seat to no key (spent at recording), where §7.4 allows a
    vacancy subject to the replacement delays.
20. **Returning vouchers exit a closed route**: a burn over the route's current client is not blocked by the
    closure (as on gno.land, where voucher returns are exit only); its refund, if the packet fails, waits for the
    reopening.

## Code pinning and the build verification

Governance pins code by hash (kinds 5, 6, 7, 9), and the pins are transitive: every contract records, as
immutables set in its constructor, the address and the code hash of each delegate it runs (the fork: its controls;
the controls: the reconciliation module; that module: the evidence module; the executor: its checks and recovery
modules), so an implementation's single pinned hash fixes its whole delegate graph. Each delegated call checks the
delegate's live code hash against the recorded one (`GnoBadModule`), kind 7 checks every module of a candidate, and
IBCAdmin checks the recovery module before running it (`ForeignExec`). Kind 7 also requires each module's recorded
own address (`gnoSelf()`) to be its address, which rejects any wrong metadata. Kind 9 requires the same of the
executor: its `bindings()` answer nothing otherwise. The delegate guard itself refuses only when the execution
context equals the recorded own address: a module that recorded the transfer proxy as its own address would refuse
delegated execution there (`NotDelegated`), while an arbitrary other address is caught by the explicit kind 7 check,
not by the guard. An ordinary proxy-backed module is therefore refused on chain: through a proxy, `gnoSelf()` answers the
implementation's address, not the module's, and kind 7 requires the module's own.

A hash says nothing of the source, and a proxy's hash never changes when its target does. So **every pinned hash
must equal a reproducible build of the named source, and no module may hold a mutable implementation pointer** (a
beacon or an ERC-1967 proxy keeps its hash while its owner changes what it runs). The on-chain checks refuse ordinary
proxies as modules and executors; the build verification also catches code that supplies acceptable metadata
without being a build of the intended source, and proxies where no on-chain check reads metadata (vouchers,
verifiers). `scripts/verify-codehashes.sh` (`script/VerifyCodehashes.s.sol`,
`script/CodeVerifier.sol`) checks against a clean build, taking no deployed byte on trust. Each contract is rebuilt in
the verifier's own simulation: its build's creation code runs at its own address, with the constructor arguments the
system's graph calls for, and the result must equal the deployed code byte for byte. So every immutable is checked
against its constructor relationship:

- a recorded own address (`_self`, UUPS's `__self`) is the contract's address;
- bindings and dependencies are the graph's actual contracts: IBCAdmin is the router's `ibcgov` app, the transfer app
  its `transfer` app, the access manager the router's authority, and each module the one its holder records;
- every recorded code hash is that dependency's live code hash.

An executor is rebuilt from its creation nonce, so the four modules it deploys come out at their recorded addresses,
and they are compared too. IBCAdmin's deployer and recovery settings are configuration values with no relationship to
check; the verifier prints them, for comparison with the deployment plan. Every rebuild is rolled back.

**Status of the coverage.** Implemented in `script/CodeVerifier.sol` and run by `scripts/verify-codehashes.sh`
(tested in `CodePinning.t.sol` and `DeploymentRace.t.sol`), which forwards `PENDING_*`, `VOUCHERS` and `CLIENTS` into
Docker (`scripts/test-verify-wrapper.sh` deploys on a throwaway anvil and checks that a mismatching extra client or
voucher fails through the wrapper): every item below. **Manual** until tooling covers it:
- running it at all (no watcher triggers it, T5 is unbuilt);
- collecting the pending decisions' hashes and candidates and a recovery proposal's `lightClient` (from gno.land's
  envelopes and the approval transactions);
- checking a verifier of any type other than GnoLightClient against its own source (`verifyLaunch` rebuilds the epoch
  client as a GnoLightClient, so after such a verifier is installed, run the other checks without it and verify that
  verifier by hand);
- **one release per run**: the verifier rebuilds every artifact from the one checkout it runs in, so the live code and
  a candidate of a different release (another source, compiler or settings) cannot both match in the same run. Verify
  the live system from a checkout of the release it runs, and each pending candidate from a checkout of the release
  it installs with `CANDIDATES_ONLY=true` (pending decisions and the listed vouchers and clients only, never the live
  code), each build reproducible from its tagged source (`scripts/test-verify-wrapper.sh` checks this with two
  builds);
- **storage-layout compatibility** before every kind 7 or kind 9: a matching build says nothing of compatibility.
  Review by hand that the candidate keeps every existing storage layout it touches (the fork's, the controls'
  namespace, eureka's ICS20Transfer namespace, IBCAdmin's), changing them only by appending, as the ADR requires;
- **verifier admission** (kind 6, kind 10's target, a recovery proposal's client): the verifier must freeze
  irreversibly, with no in-place trust reset (no path that unfreezes it, recovers it in place or restores trust in
  earlier roots). Outcomes record the verifier's address and the route's generation, which detect swaps and
  replacements but not a reset inside an unchanged verifier: an outcome proven against a poisoned root would survive
  an in-place recovery and could settle. GnoLightClient meets this requirement (it has no unfreeze or recovery
  path). Any other verifier type must be shown to meet it before it is admitted, a manual check, and its meeting
  it is a trust assumption of the controls (the alternative, a monotonic trust generation every reset advances and
  outcomes record, has no interface here).

It covers:

- **What runs now** (`verifyLive`), read from the chain and never from the deployment file, which goes stale after
  any kind 7 or 9: the transfer proxy's and the router proxy's live ERC-1967 implementation slots, the escrow and
  voucher beacons' implementations, IBCAdmin, and the executor IBCAdmin has installed, each delegate graph complete.
- **The launch's other pinned code** (`verifyLaunch`): the epoch client's verifier (a GnoLightClient, which has no
  immutables, rebuilt from any state) and the ugnot voucher registered for it (rebuilt from its own name, symbol,
  decimals and denom, its `ics20` immutable the transfer app).
- **Every pending kind 5, 6, 7 or 9, before it matures** (`verifyPending`, given `PENDING_SEQS`, `PENDING_HASHES`,
  `PENDING_CANDIDATES`): the recorded decision must have the hash of the envelope gno.land sent, name the expected
  voucher, verifier, implementation or executor, and pin that candidate's live code hash. The candidate must then be a
  build of its source: the voucher (bound to the transfer app), the GnoLightClient, the transfer app's four
  contracts, the router, the escrow or voucher implementation, or the executor and its modules.
- **Further vouchers and verifiers** (`VOUCHERS`, `CLIENTS`): every voucher a kind 5 registered and every verifier a
  kind 6 installed or an emergency recovery proposal attests (its `lightClient`, read from the approval's calldata or
  the `RecoveryApproved` transaction: IBCAdmin stores the encoded proposal in `recovery.params[hash]`, but its public
  `recovery()` view exposes only the hashes and the voting state), each rebuilt from its source.

A rebuild compares the deployed bytes with the build's, so any proxy or other code indirection fails it, whatever
its target. A verifier of another type than GnoLightClient is not covered by the tool: its operator checks by hand
that its deployed code is a reproducible build of its named source with its constructor bindings, and that it
holds no mutable implementation pointer (no proxy, beacon, `delegatecall` to a settable address or
`SELFDESTRUCT`-and-redeploy pattern), before the kind 6 or recovery that installs it matures.

**Required operating procedure** (the watch tool, T5, is not built: ADR pr6375 lists it as unimplemented, and
`scripts/verify-codehashes.sh` is run by hand with operator-supplied pending lists): run it after every deployment
and every executed decision, and for each recorded kind 5, 6, 7 or 9 and each opened emergency recovery as soon as it
is recorded, within its delay. Automating these triggers is outstanding integration work.

**A pending candidate that fails** is cancelled with **kind 1** (cancel), never kind 2 (kind 2 unpauses); for a
recovery proposal, the guardians vote to cancel it (`cancelRecovery`). Kind 1 takes the sequence ranges to cancel, `abi.encode((uint64 from,
uint64 to)[])`; to cancel the pending decision at sequence `s`, send the range `[(s, s)]` in the current epoch. The
`kind1-cancel` entry of `contracts/test/fixtures/gov-vectors.json` is a byte-exact example: epoch 1, sequence 11,
cancelling sequences 2 to 3:

```
version 01 | epoch 00000001 | seq 000000000000000b | kind 01 | params:
0000000000000000000000000000000000000000000000000000000000000020   offset of the array
0000000000000000000000000000000000000000000000000000000000000001   one range
0000000000000000000000000000000000000000000000000000000000000002   from 2
0000000000000000000000000000000000000000000000000000000000000003   to 3
```

`test_r12_3_runbookCancel_cancelsAPendingKind7` cancels a pending kind 7 this way. An ordinary proxy-backed
executor is refused on chain already: through a proxy its `bindings()` answer zero addresses, so kind 9 is spent
(`CodePinning.t.sol`). The build verification refuses it before it matures as well
(`test_r11_3_pendingProxyBackedExecutor_refused`), and catches what an on-chain check cannot: a candidate whose
bindings are right but whose code is not a build of its source.

**Live code that fails after execution** cannot be cancelled (kind 1 acts only on pending decisions). An IBCAdmin
hold defers every 7-day decision, the repair's included, so the order matters:
1. **Cancel unsafe pending decisions** (kind 1): every pending decision that relies on the failed code or would
   install unverified code.
2. **Keep the transfers contained.** Guardians set the route flags on every route (`setRouteFlag`: receives and
   escrowed sends stop) and the refunds flags (`setRefundsFlag`: refunds, claims and refund-paying kind 12 wait); a
   compromised verifier's route may be closed by replacing it (step 4). These flags are on the transfer app, not
   on IBCAdmin: route flags defer no governance, but **refunds flags defer every refund-paying kind 12** (it stays
   pending); they last while the guardians keep them (kind 2 clears them only when no hold of theirs stands).
3. **Clear the administrative flags and wait out the hold.** IBCAdmin flags (`setFlag`) defer every 7-day
   decision, so any set during the incident are cleared by their owners (`clearFlag`), and the hold ends 24 hours
   after fewer than two guardian flags stand. The repair decision, recorded meanwhile, still waits its 7 days.
4. **Execute the verified repair**, each candidate verified as pending (`verifyPending`) before it matures:
   - a failed transfer-app, router or beacon implementation: a kind 7 back to the last verified implementation
     (named in the previous `verifyLive` run) only if it meets the current requirements (for the transfer app, a
     controls version at least the running one's, and a compatible storage layout: kind 7 refuses an older
     controls version), otherwise to a compatible fixed build;
   - a failed executor: a kind 9 hand-over to a verified executor;
   - a failed voucher: none can be swapped (kind 5 registers a denom once). On Ethereum, the route flags and zero
     caps (kind 4, applied at recording) stop **ingress only** (receives); returning-voucher burns bypass both, so
     a defect that mints unbacked vouchers can still be burned into gno.land release claims with genuine Ethereum
     send records. Containment therefore also needs **gno.land's** `credits` and `payouts` flags on the route;
     then reconcile the affected gno.land receive entitlements (the authentication of a send record does not reveal
     unbacked vouchers: their supply must be audited against the escrowed backing), and clear containment only after
     a repair or the denom's retirement. Stopping the burns on Ethereum needs a governed code change (kind 7);
   - a failed verifier: a kind 10 route replacement (or the emergency recovery, if enabled at deployment), with
     `suspectFrom` covering the time it ran, whenever its history may need reconciliation: kind 6 migrates a
     client in place, with no incident, no retirement and no `suspectFrom`, and kind 12 settles only a retired
     client's records, so a kind 6 swap fits only when the old verifier's history is trusted.
5. **Reconcile** what ran meanwhile (kind 12) where the failure touched outcomes: the refunds flags are cleared first
   (their owners), since they defer every refund-paying settlement, while the route flags keep receives and escrowed
   sends stopped. Then lift the route flags (owners clear their own; kind 2 for the rest) once `verifyLive` passes
   again.

### Calls to candidate code before installation

Every call to candidate code before it is installed is a STATICCALL, so a probe cannot write state or act with the
caller's authority (`CandidateStatic.t.sol`: a candidate whose every answer first writes is refused, and its writes
never happen):

| Candidate | Call | Type |
|---|---|---|
| kind 6 verifier (add or migrate) | `IBCAdminChecks.usableClient` (a view, from the executor) → `getClientState`, `isFrozen`, `isExpired`, `lastTransition` | STATICCALL |
| recovery proposal's client | `IBCAdminRecovery._usableClient` → `IBCAdminChecks.usableClient` (as above) | STATICCALL |
| kind 9 executor | `bindings()` | STATICCALL |
| kind 7 implementation of the transfer app | `IBCAdminChecks.modulesVersion` → `CONTROLS()`, `RECONCILE()`, `EVIDENCE()`, `gnoControlsVersion()` on the implementation and its modules | STATICCALL |
| kind 7, any UUPS proxy | OpenZeppelin's `proxiableUUID()` (`view` in `IERC1822Proxiable`), during the upgrade itself | STATICCALL |
| every candidate | `extcodehash`, `extcodesize` | no call |

Code is run with authority only as installation, after the decision's pin matched: a kind 7 migration call (refused
unless the executor's allow-list names it), a kind 9 migration call (delegatecalled in the new executor), and the
router's or a beacon's switch to the new implementation. The router's `addClient` and `migrateClient` store the
client and call nothing.

### External callees during privileged operations

The transfer app's state-changing entry points (the fork, the controls, reconciliation, evidence) acquire one shared
transient lock; the UUPS upgrade path only refuses while it is held (`_authorizeUpgrade`), and eureka's `initialize` and
`initializeV2` and the `multicall` wrapper take no enclosing lock (each inner call acquires its own; `initializeGno`
acquires it). While the lock is held, IBCAdmin
refuses `execute` (`Busy`) and its delivery (a whole revert), and `drain()` records nothing. The router holds its own lock around every packet it processes. A callee therefore
reaches no privileged entry point, whatever state it sees.

| Callee (who chooses it) | Where it is called, and how | State during the call | Under the lock | Can reach a privileged entry point |
|---|---|---|---|---|
| ERC-20 token of a send (the sender) | `transferFrom` (eureka's `_transferFrom`), a CALL | tokens moved, the send record not yet written | yes | no: the lock (`CalleeReentry`, `busyGovernance`); a delivery it relays reverts whole (`test_r11_callee_tokenHookRelaysAnInboundTransfer_notConsumed`) |
| ERC-20 token or voucher of a refund (sender's token; registered voucher) | `tryPayRefund`: `balanceOf` STATICCALL (BALANCE_GAS), then `mint`/`Escrow.send` CALLs with PAY_GAS, in ack hooks, claims and kind 12; `claimParked` gives each its caller-chosen budget (at least PAY_GAS) | paid, `rec.refunded` updated after the call | yes | no: the lock (`ReentrantToken`, `HookToken` regressions); kind 12 rechecks its verifier after the payments |
| registered voucher, undoing a refund's mint (governance's kind 5) | `burn`, a CALL with all remaining gas (unbounded), only when the escrow's release failed after the mint; its failure reverts the whole call | the mint done, the release refused | yes | no: the lock |
| voucher of a returning send (governance's kind 5) | `burn`, a CALL, in the send | tokens moved to the escrow, the send record not yet written | yes | no: the lock |
| ERC-20 token of a receive | `balanceOf` STATICCALL; voucher `mint`; `Escrow.send` CALL | the receive charged and recorded before the release | yes | no: the lock |
| contract sender's ERC-165 introspection (the sender) | `supportsInterface`, at most three STATICCALLs of 30,000 gas, one word copied each, before any notification (ack hook, `holdNotice`, `notifySettled`) | after the record's outcome and payment are written | yes | STATICCALL only |
| sender adapter (the sender) | IIBCSenderCallbacks with CALLBACK_GAS in the ack hook; `retryNotification` and `notifySettled` with the caller-chosen budget (at least CALLBACK_GAS; zero: the automatic one) | after the record's outcome and payment are written; marked done after the call | yes | no: the lock (`senderReentry`, `ReentrantSender`) |
| permit2 (fixed at deployment: `PERMIT2`; unset in an ordinary deployment, so `sendTransferWithPermit2` is unavailable) | `permitTransferFrom`, a CALL, in `sendTransferWithPermit2` | as a send's token | yes | no: the lock (`test_r11_callee_permit2InSend`) |
| route's active verifier (governance's kind 6/10; never caller-supplied: `proveOutcome` reads it from storage) | `verifyMembership`/`verifyNonMembership`, CALLs (eureka's interface is not `view`) | before any write of the proof | yes | no: the lock (`test_r11_callee_verifierInProveOutcome`) |
| live client's status views (governance's) | `lastTransition`, `isFrozen`, `isExpired`, `getClientState` | — | — | STATICCALL only |
| candidates (kind 6, 7, 9, recovery proposals) | see the table above | — | — | STATICCALL only |

## Deployment

**One transfer route per governance channel.** Kind 10 and the emergency recovery act only on IBCAdmin's epoch
client (`govClient`), the client its governance travels over: the shipped deployment has one transfer route, on that
client. Another route added later (a kind 6 client with its own escrow) would have no Ethereum replacement or
recovery path of its own; operating more than one route per governance channel is unsupported.

**Activation.** The ugnot route launches inactive (zero limits). Once IBCAdmin has recorded gno.land's first decision,
gno.land sends the activating kind 4 with the parameters the deployment file names (`activationKind4Params`); it
executes after its 7 days. Until then nothing moves on the route, so a launch client that fails before gno.land binds
(when the emergency recovery is refused) leaves no value at risk: the deployment is redone.

`DeployGnoIBC` deploys the fork as the ICS20 proxy's first implementation and initializes its controls
(`initializeGno`) before the hand-over: there is no upgrade from eureka's stock ICS20Transfer and no legacy packet.
A later upgrade of the transfer app is kind 7, which installs only code that keeps the controls (the controls
version probe on the fork and its three modules, before and after the upgrade); its migration call is empty unless
a kind 9 hand-over installed an executor whose allow-list admits it.

**The launch client binding is race-free on two layers.**

1. **One transaction.** `RouterLauncher` deploys the router proxy and registers the launch Gno client in its
   constructor, so no transaction can come between them. The launch client is always the router's first, `client-0`,
   the id that every later step and gno.land's counterparty name. eureka's generated-id `addClient` is permissionless:
   with the router and its client in separate transactions, an attacker could take the predicted id in between, and
   the voucher, the controls and IBCAdmin would bind to the attacker's verifier.
   - Why this and not a custom id under the restricted overload: the launcher holds no role and needs none, so the
     deployer's privileges do not grow, not even transiently.
   - It also keeps `client-0`, which gno.land's counterparty registration, the relayer and the governance vectors
     already use.
   - A single factory for the whole deployment would exceed the contract size limit.
2. **`finishSetup` checks the deployment's own record.** The deployer passes `IIBCAdmin.Launch` (the deployer only),
   and IBCAdmin checks 11 to 15 against the chain (before `IBCAdminSetupCheck`'s list):
   - the epoch's client is that id;
   - its verifier is exactly the address the deployment created, with the recorded code hash;
   - its original checkpoint, the consensus state stored at the launch height, is the deployment's input; its
     parameters no update changes (chain id, revision, trust level, trusting period, clock drift) are too. Each of
     these two checks is skipped when its hash in `Launch` is zero (a verifier the deployment did not create);
     the ordinary deployment supplies both; its chain
     id is IBCAdmin's, and it is not frozen. Verified updates since the launch, which anyone may relay, are allowed:
     `finishSetup` never compares against state a third party can advance. For the same reason, IBCAdmin's guardian
     flags wait for setup, since a hold before it would fail check 40;
   - its counterparty is the named gno.land client, with the exact merkle prefix;
   - the ugnot voucher is registered for that id and answers to the transfer app;
   - the controls set the voucher's limits (zero ones included: the launch is inactive) and the quarantine on that id.

   Governance waits for `finishSetup`: until it passes, IBCAdmin refuses every delivery, execution and emergency
   recovery (`SetupPending`). A mismatch therefore leaves governance off, not captured.

**The launch quarantine is armed before receives exist.** The route's first quarantine setting (the deployment's)
does not checkpoint the transitions already accepted with a zero duration. Every transition its client accepted since
the trusted launch checkpoint therefore counts as live with the launch duration: anyone may relay one between the
deployment's transactions. Later governed changes keep their semantics (transitions already seen keep the duration
in force when they were accepted). Receive limits, which enable receives, are refused until the route's quarantine
is armed, and the deploy script sets the quarantine first (`test_r19_2_transitionBeforeArming_stillQuarantined`,
`test_r19_2_limitsWaitForTheQuarantine`).

`DeploymentRace.t.sol` shows both layers:
- An attacker registering between the deployer's transactions gets `client-1`, which nothing names.
- In an emulation of the old two-transaction flow, the attacker's capture of `client-0` fails `finishSetup` (check
  11), and governance over it is refused.

## Open issues

- **A freshly constructed client starts unquarantined.** A client installed by kind 6, kind 10 or the emergency
  recovery that was constructed and never updated has no transition until its first one. Marking construction as a
  transition would also quarantine the launch client. A client already updated before installation is admitted too
  (`transitionKnown` accepts a non-zero last transition), and when the route first observes its transitions, it uses their existing transition timestamps (the time the
  verifier accepted them), so a transition's quarantine may already have elapsed before installation; a route replacement keeps the old route's quarantine deadline (checkpointed before the swap), so the new
  client inherits a quarantine already started.
- **Expensive tokens are parked.** A refund paid by an ack, a claim or kind 12 gives the token 200,000 gas per call;
  a token needing more (for its transfer or its `balanceOf`, which gets 30,000) is parked, and `claimParked` pays it
  with a gas budget its caller chooses (at least the automatic one, for the balance read and each call). A caller
  starving a payment below what it needs makes the whole call revert (`GnoPaymentStarved`) rather than park it.
- **Delivering a notification needs its bytes.** Only a hash is stored, so whoever retries a notification rebuilds
  the callback calldata from the router's ack or timeout transaction (packet, acknowledgement, relayer).
- **Restricted relaying is for testing only** (`RELAYER_ADDRESS` with `ALLOW_RESTRICTED_RELAYING=true`), and even
  then the deployer cannot be the relayer: check 2 refuses any role left with the deployer.
- `scripts/e2e-local.sh` was not run end to end (it needs the gno testnet); the deployment it runs was broadcast to a
  local anvil and `finishSetup` passed.

## Tests

`contracts/test/controls/` drives the real `ICS26Router` (mock light client) through the full deployment of
`DeployGnoIBC`: `GnoICS20Transfer.t.sol`, `IBCAdminDelivery.t.sol`, `IBCAdminKinds.t.sol`,
`IBCAdminRecovery.t.sol`, `IBCAdminHoldFuzz.t.sol`, `Integration.t.sol`, `ReviewRegressions.t.sol` (the ten
review rounds' regressions, `test_r…` to `test_r10_…`), `CodePinning.t.sol` (the delegate codehashes and the build
verification), `ReconcileInvariants.t.sol` (invariant tests of the
reconciliation state machine against a ghost model: every packet's truth chosen when sent, relays honest or forged
against it, honest proofs, governance through IBCAdmin.execute; replacements also while closed or reopening,
emergency recovery and its cancellation, verifier freeze, expiry and migration, kind 12 batches and its refusals (a
mismatched action, a verifier frozen after the proof, a replay), kind 13 and its continuation over thirty-three loss
tokens, busy delivery and drain from a send hook (the delivery reverted whole, a buffered decision left unrecorded), contract
senders, their notification retries and a re-entering callback, refunds flags, claims, voucher receives, voucher
sends (burns) and their refunds (mints). Governance is also driven in separate steps (`startReplacement`,
`decideSettle`, `startReopen` record decisions that `executePending` matures and executes later, and `proveOne`
proves outcomes on its own), so other actions interleave between a decision, its proof and its execution. Further
adversaries: settlement against an expired verifier and against a proof made stale by a verifier migration (both
spent, the record unchanged), a contract sender refusing its refund notification (the refund stands), a loss booked
between deficit batches (spent, no loss changed, invariant 7), authority changes between an emergency recovery's
approval and its execution (`Suspended`), a guardian withdrawing its approval before a recovery opens (the next
approval no longer opens it), a delivered packet whose forged success ack (other bytes than the proven one) the
sender refused, settled by action 3 and then notified once with the proven ack, and success acks whose bytes vary.
Governance tightenings that apply at recording (kind 4 lowering a limit, kind 11 lengthening a quarantine) are
driven through delivery, through `drain()` behind a full drain, and from inside a token hook (refused whole, nothing
recorded), then relayed again outside; each must change the controls exactly at recording. A timeout of an unsettled
record of a retired client reaches the callback (the freeze defeated for that call) and must join the client's
processed history as suspect work, with its refund paid or owed. The defensive re-check at the last deficit batch (the route aborts its reopening rather than open with an incident
pending) is reached two ways: an ack on a retired client that is not frozen (kind 10 freezes it; the campaign
defeats the freeze for one call by running the mock client's code at the frozen client's address), which counts as
suspect work of the reopening incident, and fault injection: a test-only `vm.store` raises the pending-incident count
between batches (the word located by probing what `incidents` reads), the last batch must abort, and only the
injected bit is removed afterwards. Every `continueReopen` batch is checked for its exact incident transitions:
reopening incidents stay reopening, all become resolved when the route opens, or all open again when it aborts. The
handler runs the invariant checks between the steps of every composite (after each executed decision, each batch,
each step of a scenario), not only after each call. A generated kind 13 executes only after the handler's governance
has reconciled completely, the documented precondition (the controls' own refusals of an early kind 13 are tested
separately); the two scenarios that model governance finding a forged payout late are marked as such, and that
forged payout is exempt from the completeness check until it is booked. Payment
conservation is checked against the tokens themselves (the senders', the escrow's, bob's, the voucher's supply) and
losses as per-packet amounts that the booked losses and the accepted deficit must equal; every required transition is
covered in each run, counted only on its intended outcome, a coverage sweep after each run driving any scenario the run missed, each sweep step in its own call so that no single frame outgrows the EVM's 32 MiB memory limit; 24 runs of depth 40 in the suite). A refund-paying kind 12 under a refunds flag is driven pending → `Deferred` → executed once the flag clears (`heldSettlement`; the handler keeps deferred decisions), and kind 12's preparation gate is asserted at its own payments only: a parked refund it settled may be claimed after an unprepared reopening (`parkedAfterUnpreparedReopen`). Its invariants assume governance reconciles completely before kind 13, as §7.12 asks: the controls
themselves enforce the suspected interval and the open records, not the identification of every forged payout. Also `ProvenOutcomes.t.sol` (a strict
mock light client checks every path and value `proveOutcome` computes; the R19 vectors), `ControlsGas.t.sol`,
`GovVectors.t.sol`. Library and client tests: `Guardians.t.sol` (differential fuzz against a model),
`LeakyBucket.t.sol`, `Quarantine.t.sol`. Foundry runs in Docker, image `ghcr.io/foundry-rs/foundry:v1.7.1` (pinned:
under 1.8.1 the pre-existing `GasScaling` test runs out of gas).
