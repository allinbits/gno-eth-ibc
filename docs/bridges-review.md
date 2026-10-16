# gnolang/bridges vs this IBC v2 bridge — review and porting plan

2026-10-16. Reviewed: [gnolang/bridges](https://github.com/gnolang/bridges) `main` (ed90be0: the live
gno.land ↔ Solana bridge) and `ethereum-draft` (a58efe8: the gno.land ↔ Ethereum port of the same design),
against this repository's IBC v2 stack (`CONTEXT.md`).

## 1. What gnolang/bridges is

- **One design, two remote chains**, built on **Hyperlane** (a private deployment: our own Mailbox, no Hyperlane
  validators). gno.land locks GNOT/BUBBLE in route realms; the remote chain mints synthetic tokens.
- **Solana** (`main`): live on mainnet since 2026-10-14, "testing phase" (a small lock — 130 GNOT on launch day —
  the governor alone decides, guardians may be the operator's own keys).
- **Ethereum** (`ethereum-draft`): built, not deployed, six internal audit rounds, audit records withheld because
  several findings also hit the live Solana machines. Ethereum contracts: Hyperlane 12.2.0 `Mailbox`, two
  `HypERC20`, `MerkleTreeHook`, `ProtocolFee`; ours: `GnoLightClient` (as an ISM), `Ed25519Verifier`,
  `PausableGate`, `HlAdmin`/`HlAdminExec` (immutable). 16 deployments.
- **gno → remote**: a light client of gno.land's **ed25519** commits, written in Solidity (Ethereum) / Rust (Solana).
  Messages are proven as a `Dispatch` event inside the header's `LastResultsHash` (results leaf), not by state proofs.
- **remote → gno**: **2-of-3 operator-run ed25519 signers** ("trusted, bounded"), each reading the remote chain
  through two RPC providers that must agree and only at finality. A ZK sync-committee verifier ("Proposal 2") is
  planned, not built; the signers then remain as a 7-day-delayed fallback.
- **Around it, an extensive control system** — the part worth taking (§4).
- **Review status**: every review and audit so far is model-driven (22 design rounds, an "audit loop" of 6–8
  rounds); the plans say so ("reviewed … by nobody else yet"); a human review and an outside audit are open
  decisions. The Ethereum loop has not converged (round 5: three highs, folded). The plan documents are long and
  partly stale (e.g. Solana PLAN §10's devnet/drill timeline predates the actual 2-day build-to-mainnet).

## 2. Side by side

| | gnolang/bridges (Hyperlane, Ethereum draft) | This repo (IBC v2) |
|---|---|---|
| Protocol | Hyperlane Mailbox/HypERC20, private deployment; Hyperlane's stock relayers cannot serve it (ISM `moduleType` 0) | IBC v2 (Eureka): solidity-ibc-eureka v3.0.2 ICS26 + ICS20 on Ethereum; ICS26/ICS20 realms on gno |
| gno → Ethereum check | >2/3 of gno validator power, **ed25519 in Solidity** (~221k gas/signature) | >2/3 of gno validator power, **secp256k1 via ecrecover** (~3k gas/signature) |
| Message proof gno → Eth | results leaf (`Dispatch` event) under `LastResultsHash`; no state proofs | ICS23 membership proof of the packet commitment in gno's B+tree store under the app hash |
| Ethereum → gno check | 2-of-3 trusted signers at launch; ZK sync committee later (unbuilt) | **sync-committee light client in Gno** (BLS native) from day one; MPT storage proofs |
| Chain changes needed on gno.land | none (works on gnoland-1 today) | secp256k1 validator keys (param + every validator rotating its consensus key), `crypto/bls12381` natives, colons in realm param names (gnolang/gno#6358) |
| Header update on Ethereum | 907k gas @4 vals, **1.38M @6 (gnoland-1 today)**, 3.56M @20, 16.4M @100 (tx cap ≈85–100) | 463k @3 vals on Sepolia/Glamsterdam (≈196k on Cancun), set cached; grows ~3–5k per signature; est. ~245k @15 on mainnet pricing |
| Delivery on Ethereum | 280k (mint, fresh holder) | `recvPacket` ≈549k steady state (ICS23 proof + ICS20), 1.87M first on a client (escrow creation) |
| gno-side cost | cheap (signature checks) | ~40M gas per Ethereum client update, 94M per `RecvPacket`, 63M per ack (≈0.04–0.09 GNOT at 1 ugnot/1000 gas); ~6 KB deposit per update, never pruned yet |
| Validator-set change | **7-day quarantine** of all gno → Eth deliveries | none |
| Ethereum fork maintenance | signers: none (they read logs); Proposal 2: new verifying key per fork | the Gno client must be upgraded before forks that change light-client containers (Electra, Gloas did) |
| Upgrade/admin on Ethereum | immutable `HlAdmin` acting only on decisions **proven from gno.land's r/hlgov**; 7-day delays; guardians | `AccessManager` admin key (deployer); eureka roles |
| Controls | meters, mint limits, flags/guardians/holds, decisions with delays, governor→yield, voids, migration, monitors | eureka: per-token daily escrow rate limit, ICS20 pause, AccessManager roles; gno: authority set + GovDAO proposals, global and per-app pause, relayer allow-list, address blocklist |
| Refund on failure | none (Hyperlane messages never expire; refunds only after a migration) | IBC timeouts and error acks refund the sender |
| Interop | this one route (and the Solana sibling) | IBC v2 / Eureka ecosystem on the Ethereum side; gno-side pieces are custom (tm2 ≠ CometBFT) |
| Maturity | Solana live (small, testing phase); Ethereum draft, AI-audited, unconverged | working on Sepolia end to end; unaudited; no controls |

## 3. Advantages and disadvantages

### gnolang/bridges (Hyperlane design)

Advantages
1. **Runs on gnoland-1 as it is**: no consensus-key migration, no new natives, no param fix.
2. **The control system** (§4): bounded loss under any single failure, delays on every loosening change,
   guardians who can pause but not veto, an exit that stays open ("time to leave at the meters' rate").
3. **Cross-chain governance**: GovDAO's decisions reach Ethereum as messages the light client proves; the
   Ethereum admin is immutable code that acts on nothing else. No admin key on Ethereum after setup.
4. **Deployer-attack hardening**: `finishSetup`'s 31+1 checks, byte-for-byte audit of creation txs, code-hash
   pinned upgrades with after-checks, append-only storage layouts checked by `hlwatch`.
5. **Cheap deliveries** (results-leaf proofs, 280k) and cheap gno side.
6. **Operational depth**: signer circuit breaker on a supply identity, two-provider agreement, monitors that
   auto-flag only on integrity breaks, guardian standing orders, a public site.
7. **Same stack for Solana and Ethereum**, one set of realms/packages.

Disadvantages
1. **Ethereum → gno is trusted** (2 of 3 operator machines) until an unbuilt ZK verifier; the meters bound the
   damage, they don't remove it.
2. **ed25519 in Solidity**: ~221k gas per signature; an update costs 1.38M today and grows linearly (3.56M at 20
   validators, impossible past ~100 in one tx). A custom, forgery-critical ed25519/SHA-512 implementation (gated
   by 1.5M differential cases, not externally audited).
3. **7-day outage of gno → Ethereum on every validator-set change** (the quarantine).
4. **No interoperability gained**: a private Hyperlane deployment that Hyperlane's relayers cannot serve;
   Hyperlane `TokenRouter`/`HypERC20` ≥10.0.0 have no published audit.
5. **No expiry/refund path** for stuck messages (refunds only via migration).
6. **Large, unconverged, model-only audit surface**: ~12 decision kinds, a guardian state machine, six realms,
   ~10 Go machines each needing its own gno node and two paid RPC providers.
7. **Results-leaf proofs are fragile**: public RPC returns lossy `/block_results` JSON (non-UTF-8 bytes), a stranger's
   failed tx can make a block unprovable — open issue §11.11.
8. **Will need an upgrade if gno.land adopts secp256k1 validators**: its client refuses any non-ed25519 key.

### This repo (IBC v2)

Advantages
1. **Trust-minimised both ways from launch**: >2/3 gno validators to Ethereum; Ethereum's sync committee
   (BLS-verified natively in the GnoVM) to gno. No signer fleet, no RPC-agreement machinery.
2. **Cheap Ethereum headers that scale**: ecrecover makes the signature part nearly free, so an update stays well
   under 0.5M gas at any realistic set size (vs 1.4M–16M).
3. **Standard protocol and audited core contracts**: eureka ICS26/ICS20 (audited) instead of a private Hyperlane
   deployment; IBC timeouts and error acks give automatic refunds.
4. **No 7-day outage on validator changes** (could be added as a control, §4, but by choice).
5. **Built and proven live** on Sepolia in both directions, with Go and TypeScript relayers.

Disadvantages
1. **Needs gnoland-1 chain changes**: every validator moving to secp256k1 consensus keys (a coordinated
   governance + operator operation), the BLS natives (new, gas rows still drafts, need audit) and #6358.
2. **No controls yet**: an EOA admin over AccessManager on Ethereum; ICS20's pause blocks acks/timeouts (holds
   refunds back); gno-native vouchers are minted on Ethereum without any limit (eureka's rate limit only covers
   escrow outflows); no quarantine, no guardians, no delays, no supply monitor.
3. **Ethereum fork maintenance in Gno**: each fork that moves light-client fields needs a realm upgrade before it
   activates, or Ethereum → gno stalls.
4. **Sync-committee trust**: 2/3 of 512 unslashable validators — weaker than Casper finality, the same assumption
   the Hyperlane design reaches only after Proposal 2.
5. **Heavier per delivery** on Ethereum (ICS23 + ICS20: ~549k vs 280k) and heavy on the gno side (40–94M gas
   per message type, storage deposits growing with every update).
6. **Unaudited custom pieces**: GnoLightClient, the Gno Ethereum client, the BLS natives, the gno IBC realms.
7. **18-decimal Ethereum tokens** don't fit gno's int64 GRC20 vouchers (open; wrapper proposal in `CONTEXT.md`).

## 4. The proposal: keep vanilla IBC v2, add the bridge's controls

**Agreed.** The two designs fail differently: the Hyperlane design's protocol is weaker (a trusted way back,
linear ed25519 gas, a private transport) but its controls are much stronger; IBC v2's protocol is better and its
controls are thin. The controls are almost all transport-agnostic (the code's own state machines — `p/hlroute`,
`p/decisions`, `lib/Guardians.sol` — take callbacks, not Hyperlane types), so they port.

What does **not** port: the 2-of-3 signers and `hlverifier` (we have a light client), results-leaf proofs (we use
ICS23), checkpoint digests, `moduleType`/ISM plumbing, the remote-chain fork fallback.

### What eureka and gno-realms already give

- Ethereum: `Escrow` daily rate limit per token (fixed UTC-day windows, net of inflows; `RATE_LIMITER_ROLE`);
  `ICS20Transfer` pause/unpause (`PAUSER_ROLE`/`UNPAUSER_ROLE`) — **blocks refunds too**; AccessManager roles
  with optional execution delays; custom ERC20 registration (our `GnoVoucher`).
- gno: `p/aib/authority` (deployer + GovDAO), GovDAO proposal builders, `core.Pause` (whole packet path,
  refunds included), `core.PauseApp` (refuses sends, error-acks receives, **keeps acks/timeouts running** — the
  right semantics), relayer allow-list, transfer address blocklist, upgradeable impls.

### Controls to add, in priority order

**P0 — bound the loss of any single failure**

1. **Mint limits on Ethereum for gno-native vouchers.** Per-message maximum + leaky-bucket day cap per token
   (the gate's `_charge`: `used` drains at `dayCap`/day; launch 25,000 per message, `min(100,000, lock/10)` a
   day). We own `GnoVoucher`, so this lives in its `mint`. Covers the case eureka's rate limit doesn't.
2. **Outflow meters on gno for Ethereum → gno credits.** `p/hlroute`'s design: day cap
   `max(CapFloor, lock/10)` refilled continuously (`cap/86400` per second, ceiling one day — no midnight reset,
   ≤2 caps in any 24 h), a per-recipient meter at cap/4, payouts through a claim queue paid by a permissionless
   `Claim` (round-robin, fee as first installment, "no slivers"). In IBC terms: `OnRecvPacket` books a claim and
   returns a success ack; `Claim` unescrows/mints. Same for vouchers of Ethereum tokens. *Alternative*: refuse
   with an error ack when the meter is empty (the sender is refunded on Ethereum) — simpler, but under attack
   honest transfers bounce; the queue is the bridge's tested choice.
3. **Pausing that never traps exits**: "a pause stops minting, never burning / refunds". On gno use `PauseApp`
   (not `core.Pause`) for incidents. On Ethereum don't rely on `ICS20Transfer.pause` (it blocks
   `onAcknowledgementPacket`/`onTimeoutPacket`); put the pause in front of minting/unescrowing — `GnoVoucher.mint`
   and a gate on `GnoLightClient.verifyMembership` for receives only.
4. **Guardians with flags**: 4 guardian seats + 2 watch keys (monitors). Any one flag pauses at once; only the
   flag's owner or governance clears it (unpause waits 24 h on Ethereum and clears only flags set before it);
   two guardian flags form a **hold** that defers every 7-day decision, with a guardian replacement landing no
   earlier than day 21 of the hold. Guardians delay, never veto — unlike an AccessManager guardian, which can
   cancel. Separate flags for sends / credits / payouts on gno; a guardian's `payouts` flag may name suspect
   packets, which makes their void immediate.

**P1 — governance that a single key cannot short-circuit**

5. **Decisions with delays**: every loosening change waits 7 days (raise a cap or fee, add or swap a key,
   upgrade, enroll); tightening and removals are immediate (gno side). A ledger of numbered decisions (pending /
   applied / cancelled / spent), executable by anyone after the delay, cancellable at once, re-checked against
   live state at execution, proposals expiring after 14 days. Port `p/decisions`.
6. **GovDAO governs Ethereum through IBC**: replace the AccessManager admin key with an **immutable admin
   contract** (HlAdmin's model) that holds `ADMIN_ROLE` and every proxy, and acts only on decisions that arrive as
   IBC packets from a gno governance realm on a dedicated port (or via eureka's ICS27 GMP), proven by our
   GnoLightClient. Keep HlAdmin's in-payload `seq == last+1` rule (IBC v2 is unordered), its kind list (cancel,
   unpause, guardians, mint limits, router/client, fee, upgrade with code-hash pinning + after-checks, hand-over
   to a successor), and its 7-day group deferred by flags and holds.
7. **Governor → one-way Yield**: launch under one key with every delay in force, then a one-way `Yield` to
   GovDAO; keep the lock small until then.
8. **Quarantine after a validator-set change** in `GnoLightClient`: refuse gno → Ethereum token receives for
   7 days after a header announces a new set (governance packets exempt). Bounds a validator-set takeover (two
   GovDAO members can replace the set in one block). Costs a 7-day outage per set change — make the duration a
   governed parameter; IBC timeouts turn stuck packets into refunds.

**P2 — operations and the long tail**

9. **Supply identity + monitors**: `escrowed on gno = voucher supply on Ethereum + in flight` (and the reverse for
   Ethereum tokens), evaluated in a fixed snapshot order from own nodes; auto-flag only on integrity breaks,
   alarm on liveness; webhook alerts; a `hlwatch`-style tool for guardians and GovDAO members.
10. **Voids** (withheld / forged), restores and credit-by-vote — needed once claims are queued.
11. **Send-side limits**: per-message max/min, route fee with a floor and a ceiling (≤ cap/4), recipient filters
    (zero address, the token, bridge contracts). Order rule: raise the remote mint limit before the gno send max.
12. **Upgrade discipline**: code-hash-pinned upgrades, storage layouts append-only (checked off-chain before the
    vote), a reproducible-build check tool.
13. **Operational lessons** (each cost them a failure): own gno nodes for anything a safety rule reads (public
    load-balanced endpoints answer state and head from different backends — we hit the same with Sepolia RPCs);
    two agreeing RPC providers pinned by block hash; count only finalized Ethereum state; a policy for finality
    stalls; who pays header updates (nobody updates for free); permissionless loops (`Claim`, re-emits) are
    griefing vectors — bound their work.

### Where the two plans meet

- If gno.land adopts secp256k1 validators for IBC, their Ethereum client must be upgraded (it refuses non-ed25519
  keys) — and ours becomes cheap. Conversely, if gnoland-1 keeps ed25519, our GnoLightClient would need an
  ed25519 path (their `Ed25519.sol` is the reference) and loses most of its gas advantage.
- Their planned "Proposal 2" (ZK sync committee) is what our Gno Ethereum client already does natively.
- Both are unaudited by humans. Either way, the forgery-critical code (their Ed25519.sol; our GnoLightClient,
  Gno Ethereum client and BLS natives) needs an outside audit before real value moves.

### Suggested order of work

1. P0 items 1–4 (Solidity: `GnoVoucher` mint limits, receive gate + guardians; Gno: meters/claims in the transfer
   app, guardian flags, `PauseApp` as the incident tool).
2. P1 items 5–8 (decision ledger; immutable admin over AccessManager driven by gno governance packets; yield;
   quarantine).
3. P2 (monitor, watch tool, voids, send-side limits), then the audit.
