# Ethereum controls (ADR pr6375 E5–E9, E11, E12)

The Ethereum side of the safety and governance controls of the gno.land ⇄ Ethereum IBC ADR
(`gno.land/adr/pr6375_ibc_ethereum.md` in the gno repository, §4.4, §5.4, §6–§7, §9). This page lists what is
built, where each rule lives, and where the implementation departs from the ADR.

## Contracts

| Contract | File | What it is |
|---|---|---|
| `GnoICS20Transfer` | `contracts/src/GnoICS20Transfer.sol` | Minimal fork of eureka v3.0.2 `ICS20Transfer` (MIT); every change is marked `GNO:`. Installed by the ICS20 proxy's own UUPS upgrade. Hot path of the controls: receive checks and limits, send checks and send records, refunds (paid, metered, queued, held). |
| `GnoICS20Controls` | `contracts/src/transfer/GnoICS20Controls.sol` | The controls' governance setters, guardian flags, `claim`, views, and `ackHook` (the fork's ack/timeout settlement, reachable only through the fork's own call: a consume-once transient flag). Runs only by delegatecall from `GnoICS20Transfer`'s `fallback` (EIP-170 keeps them apart); its address is an immutable of the fork's implementation. |
| `GnoICS20Reconcile` | `contracts/src/transfer/GnoICS20Reconcile.sol` | Reconciliation: `claimParked`, `settleRecords` (kind 12), `reopenRoute` and `continueReopen` (kind 13). Reached through `GnoICS20Controls`' fallback; its address is an immutable of the controls. |
| `GnoICS20Evidence` | `contracts/src/transfer/GnoICS20Evidence.sol` | Evidence: `proveOutcome`, `gnoReceipt`, `receiveRecord`, `notifySettled`, `retryNotification`, and the `incidents` and `clientRecon` views. Reached through `GnoICS20Reconcile`'s fallback; its address is an immutable of the reconciliation module. |
| `GnoTransferStorage` | `contracts/src/transfer/GnoTransferStorage.sol` | The fork's ERC-7201 layout (`gno.storage.GnoICS20Transfer`) and the route-key helpers both halves use. |
| `IBCAdmin` | `contracts/src/admin/IBCAdmin.sol` | Permanent, immutable IBC app on port `ibcgov`: the §5.4 delivery protocol, the decision ledger, flags on itself, execution scheduling, recovery entry points, `finishSetup`. Holds `ADMIN_ROLE`. |
| `IBCAdminExec` | `contracts/src/admin/IBCAdminExec.sol` | The executor: every kind at recording and at execution. Delegatecalled at a pinned code hash; replaced only by kind 9. |
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
- **`gno.storage.GnoICS20Transfer`** (`GnoTransferStorage.Layout`): guardian keys (IBCAdmin's copy), `routeOf`
  (client id → route key), `currentOf` (route key → current client id), `retired`, per route: pause flags, refunds
  flags, quarantine seconds and the deadline of transitions already seen, recovery block, `closed`; per (route,
  token): limits, receive bucket, refund bucket, refund queue, the escrow reserved for owed refunds and outstanding sends, recorded losses
  and the part accepted as a deficit; per route: its open-record count and the tokens with losses; per (client id,
  sequence): the send record (open flag, settlement, proven destination outcome with its verifier and verifier
  generation, its index in the route's processed list) and the hash of a sender notification held until its refund
  is paid, or kept after a failed delivery (never its bytes); per (client id,
  inbound sequence): every receive's token and amount in one slot; per route the append-only list of every ack and
  timeout it processed (client id, sequence, block), the floor below which the last reopening left every record
  reconciled, and, for its last replacement, `suspectFrom`, the first processed index of the suspected compromise
  interval and how many records of that interval are still unsettled, and its verifier generation (bumped before every
  verifier swap and replacement). Guardian keys carry a monotonic generation per
  seat, and each flag stores the generation of the key that set it, so a flag stands only if the seat's current key
  set it.
  - A replacement on IBCAdmin's key list reaches the transfer app's copy (`setGuardianKeys`), which retires the
    replaced keys' flags by generation without touching that flag set's hold moments.
  - The hold reads them lazily: a hold left with fewer than two standing guardian flags and no dip ends.
  - So does a dip in which a guardian flag that stood when the dip started is still set but no longer stands. Its
    key was replaced (`dipMask` records the seats standing at the dip's start), and this ends the hold at once, as a
    replacement on the same flag set does. An owner's own clear keeps the 24-hour grace.
- **`gno.storage.IBCAdmin`** (`IBCAdminStorage.Layout`): epoch, last seq, epoch client, last record time, conflict
  flag, executor and its code hash, decisions and tombstones keyed by epoch, guardian keys and flags, hold history,
  recovery state, `setupDone`, the decision that last set each setting (`appliedSeq`), gno.land's chain id, the client
  ids kind 6 added (`enrolled`, the only ids kind 10 may move a route to).

## Roles (AccessManager)

| Function | Role | Holder after the setup |
|---|---|---|
| every state-changing entry point of the fork, the controls and the reconciliation module (sends, packet callbacks, claims, guardian flags, governed setters, settlement and reopening, proofs, notifications, `setCustomERC20`, the beacon and UUPS upgrades) | one shared transient reentrancy lock; `gnoBusy()` reads it | — |
| everything governed: router `addIBCApp(string,…)`, `addClient(string,…)`, `migrateClient`, `upgradeToAndCall`; transfer `setCustomERC20`, `upgradeToAndCall`, beacons, every control setter (`initializeGno`, `setGuardianKeys`, `setLimits`, `setQuarantine`, `unpauseRoute`, `setRecoveryBlock`, `migrateRoute`) | `ADMIN_ROLE` | `IBCAdmin` only |
| `recvPacket`, `ackPacket`, `timeoutPacket`, `updateClient` | `PUBLIC_ROLE` (or `RELAYER_ROLE` if `RELAYER_ADDRESS` is set) | anyone / kind 8 |
| transfer `pause` / `unpause` | `PAUSER_ROLE` / `UNPAUSER_ROLE` | nobody (ADR §7.3) |
| `sendTransferWithSender` | `DELEGATE_SENDER_ROLE` | nobody |

The deployer never holds `ID_CUSTOMIZER_ROLE` or `ERC20_CUSTOMIZER_ROLE` (those functions are `ADMIN_ROLE`'s) and
renounces `ADMIN_ROLE` at the end of `DeployGnoIBC`, which then runs `IBCAdmin.finishSetup(launch)`.

## The governance wire format (for `ibcgov`)

As ADR §5.4 has it (amended 2026-10-16 with the implementation):

- Payload: `sourcePort = "gov"`, `destPort = "ibcgov"`, `version = "ibcgov-1"`, `encoding = "application/x-ibcgov"`.
- Envelope: `version u8 (1) ‖ epoch u32 ‖ seq u64 ‖ kind u8 ‖ params`, big-endian, at most 1024 bytes;
  `params = abi.encode(field1, field2, …)` of the kind's tuple (no outer offset).
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
  - gno.land answers in IBCAdmin's ack layout, `epoch u32 ‖ seq u64 (0) ‖ status u8 ‖ redispatch u8 (0)`: status 1
    (switched) or 3 (already switched) for that epoch ends it.
  - An error ack, a timeout, or a send the router refused leaves it owed: anyone calls `resendEpochNotice(epoch)`,
    which sends the same bytes again.
  - Each epoch keeps its own notice, so after consecutive replacements (A→B→C: epoch 2 over B, epoch 3 over C) each
    stays re-sendable on its own, and gno.land may skip ahead.
  - The ack and timeout callbacks handle notices and ignore anything else; they never revert.
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
  receive callback, with the router locked). The epoch switch stands and the notice stays owed for
  `resendEpochNotice` (`test_epochNotice_refusedInitialSend_resendCompletes`).
- **Vacancies.** Kind 3 never sets a seat to no key: a vacancy is spent at recording, so it can never land faster than
  a replacement (ADR §7.4).
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
| E6 send limits for escrowed (Ethereum-native) tokens only (`sendMax`/`sendMin`, 0 = unset); returning vouchers never limited or paused | `_checkEscrowedSend`, skipped when `burned` |
| E6/§7.13 send record in every send variant after `sendPacket` returns the sequence (`sendTransfer`, `…WithPermit2`, `…WithSender`) | `_recordSend` (all three go through `_sendTransferFromEscrowWithSender`) |
| §7.13 records hold the router's commitment, not the packet bytes (bytes in `SendPacket`, authenticated against it); an ack or timeout without a record is refused (`GnoNoSendRecord`; none can exist on a fresh deployment) | `_recordSend`; `GnoICS20Controls.ackHook` |
| §7.13 ack/timeout attach outcome, local processing block and payment state | `GnoICS20Controls.ackHook` |
| §7.13 refund meter per (route, token), queue beyond it, permissionless `claim` (installments); the meter is charged before the token moves (given back if the payment fails), and its limits cannot change mid-payment (shared lock; IBCAdmin refuses while busy) | `GnoICS20Controls.ackHook`, `claim` |
| §7.12 escrow per route and token never falls below the reservation: owed refunds (queued, parked, decided but unpaid) and outstanding escrowed sends (no ack or timeout yet, not settled), whose refund could still be owed. A receive below it is an error ack (`GnoEscrowReserved`); a refund (at once, claim, `claimParked`, kind 12) that would take another record's backing is parked; vouchers reserve nothing | `GnoTransferStorage.reservation/syncReserve/tryPayRefund`; `GnoICS20Transfer.onRecvPacket`, `_recordSend` |
| a refund the token or escrow refuses (blacklisted sender, paused token) is parked, never blocking the ack or the queue; `claimParked` retries it | `GnoTransferStorage.tryPayRefund`; `claim`, `claimParked` |
| a sender's `IIBCSenderCallbacks` notification of an error ack or timeout is delivered when its refund is paid at once, with at most 100,000 gas and only when 60,000 more remain for the caller. Only its hash is ever stored (held, or kept after a failure): a claim, `claimParked` or kind 12 paying it only marks it due (`GnoNotificationDue`), and anyone delivers it with `retryNotification(clientId, sequence, call, gasBudget)`, `call` being the callback calldata the router's ack or timeout carried, authenticated against the hash, with a caller-chosen gas budget (at least the automatic 100,000; a caller sending too little for it and the reserve reverts `GnoNotificationStarved`); a failing notification never rolls the refund back; a rejected refund's notification is dropped | `GnoTransferStorage.notify/holdNotice/releaseNotice/retryNotice`; `GnoICS20Evidence.retryNotification` |
| one terminal notification per send record, decided by its final outcome: the transport's (success or refund) until kind 12 settles it, then the settlement's (action 1 a refund, actions 2 to 4 a success). A settlement deciding another kind supersedes the saved transport notification (it is never delivered after); a permissionless `notifySettled(packet, ack, gasBudget)` delivers the settlement's once: the refund (`onTimeoutPacket`) once paid in full, or the success (`onAckPacket(true, …)`) with the ack `proveOutcome` proved (kept as a hash), which covers a delivered outstanding packet settled by action 3; the packet authenticated against the record's commitment, retried by calling again. A success the transport announced but never delivered (the sender refused it) is replaced by the proven one once actions 2 or 3 settle it, even when both are successes: the transport's ack may be forged. After that settlement, `retryNotification` takes only a call carrying the proven ack, and `notifySettled` delivers it once. Delivering through either path marks the other done, so the sender is told of the success exactly once | `GnoICS20Reconcile.settleRecords`; `GnoICS20Evidence.notifySettled`; `GnoTransferStorage.noticeKinds/deliverSettled` |
| §7.13 refunds hold suspends proof-based refunds and claims, cancels nothing, follows the ordinary flag and hold rules | route `refundFlags`; `setRefundsFlag`/`clearRefundsFlag`; `unpauseRoute`; checked in `ackHook`, `claim`, `claimParked` |
| §7.3 a pause never blocks acks, timeouts or refunds; PAUSER_ROLE granted to nobody | `whenNotPaused` removed from the ack/timeout callbacks; deployment roles |
| E7 4 guardian + 2 watch seats, flags, holds (two guardian flags), 24 h hold end, unpause clears earlier flags, refused under a hold | `Guardians`; per route in the fork, on IBCAdmin itself |
| a replaced key's flags die on every flag set, and stay dead if the key returns (seat generations) | `Guardians.Keys.since`, `setKeys`, `standing` |
| E7 route flags block receives and Ethereum-native sends only | `_checkReceiveRoute`, `_checkEscrowedSend` |
| E9 live-epoch quarantine, anchor-independent; fail closed: a client whose `lastTransition()` is missing, reverts or answers anything but two uint64 words refuses receives and quarantine changes (`GnoQuarantineUnknown`), and is never installed; a duration applies to transitions accepted after it, a started quarantine keeps its deadline; transitions told apart by number; a duration change reads the route's current client, whichever id names it; the deadline of a started quarantine is checkpointed before any verifier swap (kind 6 op 2) or route replacement (kind 10), so the new client cannot end it early; governance not quarantined | `GnoLightClient._isLiveTransition`, `lastTransition`; `GnoTransferStorage.quarantineUntil`; `GnoICS20Controls.setQuarantine` settles; never checked by IBCAdmin |
| §5.4 envelope, acks, statuses, window W = 64, drain D = 8 (every delivery and `drain()`), duplicates, conflicts | `IBCAdmin.onRecvPacket`, `_deliver`, `_record`, `_drain` |
| §5.4 cancels anywhere: tombstones on arrival of the ranges as given (≤ 64 merged per epoch), a cancel beyond the window bound to its hash, redispatch | `IBCAdmin._deliver`, `_parseCancel`, `_tombstone`; `IBCAdminStorage.addTombstone` |
| §5.4 epochs: another epoch refused, everything keyed by (epoch, seq) | `IBCAdmin.onRecvPacket`; `IBCAdminStorage.Layout` |
| §5.4 unknown kind / bad params recorded and spent; a decision's parameters must be exactly the canonical `abi.encode` of its tuple (decoded, re-encoded and compared: trailing data, offsets or padding otherwise are spent at recording); a decision failing its checks at execution spent (no code, another code hash, a refused call, failed after-checks, rolled back) | `IBCAdmin._record`, `execute`; `IBCAdminExec.atRecording`, `_codeIs`, `_call`, `_selfStep` |
| no one spends a decision by starving it of gas: recording, refusable calls and self-steps run with fixed budgets and floors | `IBCAdmin._atRecording`; `IBCAdminExec._call`, `_selfStep` |
| §5.4 kind delays: cancel / kind 4 tightening / kind 8 revoke / kind 11 lengthening at recording; unpause 24 h; others 7 d | `IBCAdminExec.atRecording`, `IBCAdmin.execute`, `_delay` |
| §6.6/§7.4 7-day kinds deferred by flags and holds; kind 3 through flags, through a hold at ≥ day 21 | `IBCAdmin.execute`, `_replacementFloor` |
| §7.4 unpause spent under a hold of its object (a route: its flags or refunds flags) | `IBCAdminExec._unpause` |
| kind 3 at most 2 guardian seats, never a current key; both key copies follow; a replaced seat loses its recovery approval | `Guardians.checkReplace`; `IBCAdminExec._seats` |
| kind 4 limits, "no field loosens" rule; an older decision maturing later never overwrites a newer setting (kinds 4, 11) | `IBCAdminExec._loosens`; `IBCAdminStorage.supersede` |
| kind 5 voucher registration, code-hash pinned, bound to the fork; the base denom only in the wire grammar shared with gno.land's ibcgov builder (`isGnoWireDenom`, gno-realms 3852a93), at most 128 bytes: native `[a-z][a-z0-9]{2,15}`; or a GRC20 alias, the literal `gno.land:r`, then at least two `:`-separated segments each matching Gno's `Re_name` `[a-z][a-z0-9]*([_-][a-z0-9]+)*` (single `_` or `-` separators, never leading, trailing or doubled: `gno.land:r:my-org:token.TKN` qualifies), then optionally `.` and a slug of 1 to 32 `[A-Za-z0-9_-]`. Realm-issued coins (`/gno.land/r/...:denom`) are refused; the gno side never sends them. Anything else is spent at recording | `IBCAdminExec._voucher` |
| kind 6 add (custom id, enrolled for kind 10) / migrate a client (quarantine checkpointed and the verifier generation bumped first), code-hash pinned; the verifier usable: for gno.land's chain id, neither frozen nor expired (`IBCAdminChecks.usableClient`, as the emergency recovery checks); the counterparty only in canonical form (gno.land's exact merkle prefix `main`, `/pv/vm:gno.land/r/aib/ibc/core:`, and a client id in [a-z0-9-], 1 to 64 characters; spent at recording otherwise), and a swap keeps the client's counterparty id; a retired client id is never migrated (spent); the emergency recovery's proposal is held to the same counterparty rule | `IBCAdminExec._client`; `GnoICS20Controls.checkpointQuarantine` |
| kind 7 upgrades (router, transfer app, its two beacons), code-hash pinned, fixed call gas, after-checks (including that every beacon the decision does not name keeps its implementation and owner), a migration call that is empty or carries a selector on the executor's pinned allow-list (`migrationAllowed`: empty in this executor, so every migration call is refused; only a kind 9 hand-over to an executor with its own list extends it), and under any list never an upgrade-setting selector (`upgradeToAndCall`, `multicall`, `upgradeEscrowTo`, `upgradeIBCERC20To`), and on the transfer proxy only code that keeps the controls (`gnoControlsVersion()` at least the running one's, on the implementation before and on the proxy after: never the stock ICS20Transfer or an older fork), rolled back whole on failure | `IBCAdminExec._upgrade`, `migrationAllowed`, `applyUpgrade` |
| kind 8 relayer role only; never ADMIN or any role that upgrades or re-points | `IBCAdminExec.atRecording`/`run` |
| kind 9 hand-over: swap the pinned executor (same bindings), optional migration call, rolled back whole on failure | `IBCAdminExec._handover`, `applyHandover` |
| kind 10 / E12 route replacement `(string oldClientId, string newClientId, uint64 suspectFrom)`: only to a client id kind 6 enrolled, whose verifier is still usable (gno.land's chain id, neither frozen nor expired) immediately before the old route is retired and the epoch switches (spent otherwise, the old route untouched); quarantine checkpointed; retire + freeze the old id, `migrateRoute` (a new incident; the route closes), next epoch over the new id; allowed while the route is closed (an earlier incident carries over untouched; a reopening under way is aborted), only from the route's current client | `IBCAdminExec._route`; `IBCAdminStorage.replaceRoute`; `GnoICS20Controls.migrateRoute` |
| §7.12 suspected compromise interval, per incident: every ack and timeout the retired client processed from block `suspectFrom` on (found by binary search in that client's own processed list), and any it processes later, must be settled by kind 12 before kind 13; the live client's never count; the emergency recovery proposal carries the same field (the reconciliation state machine above) | `GnoICS20Controls.migrateRoute`, `ackHook`, `suspectRecords`; `GnoICS20Reconcile.settleRecords`, `reopenRoute` (`GnoSuspectUnsettled`) |
| kind 11 route quarantine setting | `IBCAdminExec.atRecording`/`run`; `GnoICS20Controls.setQuarantine` |
| §7.12 proven outcomes: anyone proves a send record's destination outcome through the route's replacement client (`proveOutcome`): the packet authenticated against the record's commitment, gno.land's receipt recomputed (R19: `sha256(0x03 ‖ uint64be(sequence) ‖ sha256(sourceClient) ‖ packet commitment)`, the gno-realms vectors) and compared with the proven one, the ack commitment proven with it; delivered (its receipt, a success ack), refundable (an error ack, or no receipt once the proven time reaches the packet's timeout), or a collision (another receipt at the sequence); final once proven; the replacement client must be active (the route's current client, neither frozen nor expired) when the outcome is proven and when kind 12 uses it: the outcome stores its verifier and the route's verifier generation, and one whose verifier has since frozen, expired or been replaced, or whose route was re-pointed since (even back to the same client), is void (kind 12 refuses it, all or nothing, and a new proof through the active client may replace it); kind 12 checks the verifier again for every outcome it consumes and after its last payment, so a token hook that freezes or swaps it mid-batch rolls the batch back. GnoLightClient has no path that unfreezes it or restores trust in earlier roots | `GnoICS20Reconcile.proveOutcome`, `gnoReceipt`, `_activeClient` |
| kind 12 settle: per send record of a retired client id, at most once, all or nothing, with a fixed 6M gas budget and at most eight records (more is spent at recording), each action matching the proven outcome (else the decision is spent): 1 a genuine refund (refundable or collision), `amount` equal to its whole remainder (parked if refused), zero for a refund already paid in full (which only settles the record), 2 reject a queued refund, 3 settled as delivered (2 and 3 delivered, refused once any of the refund was paid), 4 forged refund (delivered: reject the unpaid remainder, book what was paid as the loss); 5 a forged receive at an inbound sequence of the retired client, booked as a loss once for exactly the amount the receive recorded. Two passes: the first validates and settles every item and owes every action 1 refund its whole remainder, so each one's reservation is restored (a refund a forged success ack hid included); only then does the second pass pay those refunds, each against the batch's complete reservations, in any item order. An ack or timeout of a settled record pays nothing and notifies nobody | `IBCAdminExec.run`; `GnoICS20Reconcile.settleRecords`; `GnoICS20Controls.ackHook` |
| kind 13 reopen a closed route only when none of its send records is open (an O(1) count: opened by a send, closed by a success ack, a refund paid in full or a settlement); and none of its suspected-interval records is unsettled; every loss not recapitalized becomes an accepted deficit (`GnoDeficitAccepted`, `acceptedDeficit`), 16 tokens in kind 13 and the rest in bounded batches by a permissionless `continueReopen` (the route stays closed, `routeReopening`, until the last); reconciliation is sealed while the route reopens (kind 12 refused, `GnoRouteReopening`), and the last batch checks the prerequisites again before the route opens (a record opened meanwhile keeps it closed, `GnoReopenAborted`); a closed route refuses receives, sends and claims | `GnoICS20Reconcile.reopenRoute`, `continueReopen`; `GnoTransferStorage.openRecord/closeRecord`; `_checkReceiveRoute`, `_sendTransferFromEscrowWithSender`, `_openRoute` |
| E12 route keys, constant-work migration, wire translation | `GnoTransferStorage.routeKey/toRouteDenom/toWireDenom`; `migrateRoute` |
| §7.12 emergency recovery, off unless enabled at deployment; approval ≥ 3 of 4 guardians, cancellation by a guardian majority (≥ 3 of 4); eligibility; an attested client of gno.land's chain id, neither frozen nor expired at approval and at execution; a long public delay of at least 30 days (`MIN_RECOVERY_DELAY`, enforced by the constructor and the deploy script); suspends kinds 3, 6–10 at recording and at execution; blocks receives while open; the route stays closed after it | `IBCAdmin` constructor, `approveRecovery/cancelRecovery/executeRecovery`; `IBCAdminRecovery` |
| E4/E11 hand-over of every authority, deployer roles removed, check list read back | `script/DeployGnoIBC.s.sol`; `IBCAdmin.finishSetup`; `IBCAdminSetupCheck` |
| §7.2/§9 launch values from the expected lock: day cap min(100,000 GNOT, lock/10), max per message min(25,000 GNOT, day cap), refund cap the day cap; overrides only lower; quarantine 7 d | `DeployGnoIBC._launchLimits`, `_deploy` |

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
    router committed (the packet's own data), never changed after the send.
4b. Payments conserve tokens: every sender holds what it had, less what it sent, plus exactly the refunds its
    records show; the escrow holds what was sent, less every refund and every receive; receivers hold exactly what
    was received; a voucher's supply moves only by receives, returns and refunds. An undelivered packet's sender
    ends refunded its packet's full amount, or the remainder stays reserved.
4c. Kind 12's actions agree with the proven outcomes (a refund only for a packet not delivered, a delivered
    settlement only for one delivered), and the losses booked equal the forged payouts as amounts.
5. Escrow per route and token is at least the reservation (owed refunds and outstanding sends, §7.12). A refund a
   forged success ack hid is reserved from the moment `proveOutcome` proves it owed (refundable or a collision),
   not from its settlement. Its backing is therefore held however the settlements are split across decisions. The
   liability outlives the proof (`held`). If the verifier that proved it stops vouching for it, anyone may call
   `voidOutcome` so that the active verifier can prove it again; the reservation stays. Only its settlement, or a
   new proof through the active verifier that the packet was delivered, releases it. `voidAndReprove` drives three
   such refunds against deficient backing: proven, verifier migrated, two voided, one re-proven and settled; it must
   not pay. The only
   permitted shortfall is the one reconciliation recognizes: the refunds kind 12 owes again for packets a forged
   success ack released, whose backing the compromise consumed. That allowance belongs to those very refunds and
   only while they are unpaid. Every other record's reservation is backed in full at all times, so a payment of one
   refund never takes another's backing, and no receive or payment ever increases the shortfall.
   The invariant campaign checks this from its own ghost. It marks the eligible refunds when it proves them owed, and bounds the allowance by their unpaid part and by what was uncovered at the previous step (lowered at
   every step, never raised but by kind 12). It asserts that the escrow covers every reservation but the eligible
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
| replacement (kind 10, emergency recovery) | the old id is the route's current client; the new id fresh | a new *replacement* incident covering the old id (suspect range from `suspectFrom`); the route closes; a reopening under way is aborted (its incidents back to *open*); earlier incidents, their records, reservations and counters untouched. Allowed while the route is closed |
| ack or timeout | a record of the client | appended to the client's processed list; counted as suspect only if the client is retired |
| delivery or drain of a governance decision | the transfer app not busy (a delivery from inside a hook reverts whole with no data, so the router writes nothing and the packet is relayed again later; `drain()` records nothing) | the decision recorded; one acting at recording (kind 4 or 11 tightening) applies |
| kind 12 on a retired client's records | its incident not *reopening*; the outcome proven by the active verifier | the record settled once; its client's open and suspect counts follow |
| kind 12 booking a loss | the route not reopening | the loss recorded; if the route was open, a *late-loss* incident opens and the route closes |
| kind 13 | the route closed and not reopening; `pendingIncidents` zero (every replacement's client with no open and no suspect record; a late loss needs none) | `reopenUpTo` moves to the end: unresolved incidents become *reopening*; deficits accepted in batches (`continueReopen`) |
| last deficit batch | — | `pendingIncidents` checked again (defensive: with the reopening incidents sealed, their clients frozen and no backfill, no record can open meanwhile): zero → `resolvedUpTo` moves to `reopenUpTo` (*resolved*), the route opens; otherwise the reopening aborts (`reopenUpTo` back: incidents *open*, the route stays closed) |

Each client id is retired once, so its suspect range never overlaps another incident's and a record reconciled by
one incident is never counted by another; nothing is counted on the live client.

## Execution of decisions, per kind

`IBCAdmin.execute` checks, before anything runs: the decision pending and not tombstoned, not suspended by an open
recovery, not deferred by flags or holds, mature, the transfer app not busy (`Busy`: a transfer-app entry point is
running, so a token or sender hook called in), the executor's code the pinned one (`ForeignExec`), and the caller's
gas at least the kind's frame (`CallStarved`). Each of these reverts and leaves the decision **pending**. Then the
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
| 10 route | 2.5M | transfer `checkpointQuarantine`, `migrateRoute` (refusable); router `migrateClient` (freeze) | `client`, `route`; a revert | same |
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
5. **Kind 10 is also suspended while an emergency recovery is open** (the ADR lists kinds 3 and 6–9).
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
12. **Seat generations**: a flag stores the generation of the key that set it rather than a block, so a key removed
    and restored in the same block cannot revive its earlier flags.
13. **A proven non-receipt waits for the packet's timeout.** The ADR counts a non-receipt as refundable because the
    destination's old client is frozen; Ethereum cannot prove that freeze, so `proveOutcome` takes a non-receipt
    only at a proof height whose destination time (the replacement client's, returned with the proof) reaches the
    packet's timeout (eureka caps timeouts at one day), as the amended §5.4 has it.
14. **A reconciliation refund's notification is `onTimeoutPacket`** (the packet was not delivered), delivered by
    `notifySettled`; a settlement only marks a held notification due, which `retryNotification` delivers.
15. **Receives record their amount in 96 bits**: a receive above 2^96 - 1 is refused (an error ack), far beyond any
    receive limit, so kind 12 action 5 can check the amount from one slot.
16. **Outstanding sends reserve their escrow**: a redemption from gno.land cannot release escrow that an outstanding
    send may have to refund; an honest redemption is covered by the delivered sends' escrow. Sends are capped at
    2^96 - 1, as receives.
17. **A loss found after a route reopened closes it again** (`GnoRouteClosedForLoss`) until a new kind 13 accepts it;
    that reopening does not wait for the live client's open records.
18. **Kind 7 on the transfer proxy checks the fork's modules**: its controls and reconciliation modules must be code
    answering its controls version, and all three answer through the proxy after the upgrade.

## Code pinning and the build verification

Governance pins code by hash (kinds 5, 6, 7, 9), and the pins are transitive: every contract records, as
immutables set in its constructor, the address and the code hash of each delegate it runs (the fork: its controls;
the controls: the reconciliation module; that module: the evidence module; the executor: its checks and recovery
modules), so an implementation's single pinned hash fixes its whole delegate graph. Each delegated call checks the
delegate's live code hash against the recorded one (`GnoBadModule`), kind 7 checks every module of a candidate, and
IBCAdmin checks the recovery module before running it (`ForeignExec`). Kind 7 also requires each module's recorded
own address (`gnoSelf()`) to be its address. Kind 9 requires the same of the executor: its `bindings()` answer
nothing otherwise. A module whose own address was recorded as another would refuse every delegated call
(`NotDelegated`), and a module behind a proxy answers its implementation's address.

A hash says nothing of the source, and a proxy's hash never changes when its target does. So **every pinned hash
must equal a reproducible build of the named source, and no module may hold a mutable implementation pointer** (a
beacon or an ERC-1967 proxy as a module would keep its hash while its owner changed what it runs; on chain it
passes, as governance pinned it). `scripts/verify-codehashes.sh` (`script/VerifyCodehashes.s.sol`,
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
check; the verifier prints them, for comparison with the deployment plan. Every rebuild is rolled back. It covers:

- **What runs now** (`verifyLive`), read from the chain and never from the deployment file, which goes stale after
  any kind 7 or 9: the transfer proxy's and the router proxy's live ERC-1967 implementation slots, the escrow and
  voucher beacons' implementations, IBCAdmin, and the executor IBCAdmin has installed, each delegate graph complete.
- **Every pending kind 7 or kind 9, before it matures** (`verifyPending`, given `PENDING_SEQS`, `PENDING_HASHES`,
  `PENDING_CANDIDATES`): the recorded decision must have the hash of the envelope gno.land sent, name the expected
  implementation or executor, and pin that candidate's live code hash. The candidate's whole graph must then be a
  build of its source: the transfer app's four contracts, the router, the escrow or voucher implementation, or the
  executor and its modules.

The watch tool (T5) runs both: after every deployment and every executed decision, and for each recorded kind 7 or 9
as soon as it is recorded, within its seven-day delay. A failure is the signal to cancel the decision with **kind 1**
(cancel), never kind 2 (kind 2 unpauses). Kind 1 takes the sequence ranges to cancel, `abi.encode((uint64 from,
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

`test_r12_3_runbookCancel_cancelsAPendingKind7` cancels a pending kind 7 this way. On
chain, a hand-over to an executor behind a proxy would pass, since its bindings answer through the proxy and its hash
is the one governance pinned; only this step refuses it (`test_r11_3_pendingProxyBackedExecutor_refused`).

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

Every state-changing entry point of the transfer app (the fork, the controls, reconciliation, evidence) holds one
shared transient lock. While it is held, IBCAdmin refuses `execute` (`Busy`) and its delivery (a whole revert), and
`drain()` records nothing. The router holds its own lock around every packet it processes. A callee therefore
reaches no privileged entry point, whatever state it sees.

| Callee (who chooses it) | Where it is called, and how | State during the call | Under the lock | Can reach a privileged entry point |
|---|---|---|---|---|
| ERC-20 token of a send (the sender) | `transferFrom` (eureka's `_transferFrom`), a CALL | tokens moved, the send record not yet written | yes | no: the lock (`CalleeReentry`, `busyGovernance`); a delivery it relays reverts whole (`test_r11_callee_tokenHookRelaysAnInboundTransfer_notConsumed`) |
| ERC-20 token or voucher of a refund (sender's token; registered voucher) | `tryPayRefund`: `balanceOf` STATICCALL, then `mint`/`Escrow.send` CALLs with PAY_GAS, in ack hooks, claims, `claimParked`, kind 12 | paid, `rec.refunded` updated after the call | yes | no: the lock (`ReentrantToken`, `HookToken` regressions); kind 12 rechecks its verifier after the payments |
| ERC-20 token of a receive | `balanceOf` STATICCALL; voucher `mint`; `Escrow.send` CALL | the receive charged and recorded before the release | yes | no: the lock |
| sender adapter (the sender) | IIBCSenderCallbacks with CALLBACK_GAS (ack hook, `retryNotification`, `notifySettled`) | after the record's outcome and payment are written; marked done after the call | yes | no: the lock (`senderReentry`, `ReentrantSender`) |
| permit2 (fixed at deployment) | `permitTransferFrom`, a CALL, in `sendTransferWithPermit2` | as a send's token | yes | no: the lock (`test_r11_callee_permit2InSend`) |
| route's active verifier (governance's kind 6/10; never caller-supplied: `proveOutcome` reads it from storage) | `verifyMembership`/`verifyNonMembership`, CALLs (eureka's interface is not `view`) | before any write of the proof | yes | no: the lock (`test_r11_callee_verifierInProveOutcome`) |
| live client's status views (governance's) | `lastTransition`, `isFrozen`, `isExpired`, `getClientState` | — | — | STATICCALL only |
| candidates (kind 6, 7, 9, recovery proposals) | see the table above | — | — | STATICCALL only |

## Deployment

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
     parameters no update changes (chain id, revision, trust level, trusting period, clock drift) are too; its chain
     id is IBCAdmin's, and it is not frozen. Verified updates since the launch, which anyone may relay, are allowed:
     `finishSetup` never compares against state a third party can advance. For the same reason, IBCAdmin's guardian
     flags wait for setup, since a hold before it would fail check 40;
   - its counterparty is the named gno.land client, with the exact merkle prefix;
   - the ugnot voucher is registered for that id and answers to the transfer app;
   - the controls set the voucher's limits and the quarantine on that id.

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

- **A newly added client starts unquarantined.** A client installed by kind 6, kind 10 or the emergency recovery
  has no transition until its first one. Marking construction as a transition would also quarantine the launch client.
- **Expensive tokens are parked.** A refund paid by an ack, a claim or kind 12 gives the token 200,000 gas per call;
  a token needing more (for its transfer or its `balanceOf`, which gets 30,000) is parked, and `claimParked` pays it
  with a gas budget its caller chooses (at least the automatic one, for the balance read and each call). A caller
  starving a payment below what it needs makes the whole call revert (`GnoPaymentStarved`) rather than park it.
- **Delivering a notification needs its bytes.** Only a hash is stored, so whoever retries a notification rebuilds
  the callback calldata from the router's ack or timeout transaction (packet, acknowledgement, relayer).
- **The deployer cannot be the relayer** (`RELAYER_ADDRESS`): check 2 refuses any role left with the deployer.
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
covered in each run, counted only on its intended outcome; 24 runs of depth 40 in the suite). Its invariants assume governance reconciles completely before kind 13, as §7.12 asks: the controls
themselves enforce the suspected interval and the open records, not the identification of every forged payout. Also `ProvenOutcomes.t.sol` (a strict
mock light client checks every path and value `proveOutcome` computes; the R19 vectors), `ControlsGas.t.sol`,
`GovVectors.t.sol`. Library and client tests: `Guardians.t.sol` (differential fuzz against a model),
`LeakyBucket.t.sol`, `Quarantine.t.sol`. Foundry runs in Docker, image `ghcr.io/foundry-rs/foundry:v1.7.1` (pinned:
under 1.8.1 the pre-existing `GasScaling` test runs out of gas).
