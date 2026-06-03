# Phase 5d — Realtime, Cadence & Sync Observability (Design Spec)

> **Date:** 2026-06-02 · **Status:** design approved in brainstorming; **NOT yet planned or implemented**. Basis for the implementation plan. Next: write the plan (`docs/superpowers/plans/2026-06-02-phase-5d-realtime-status.md`), then execute. **Final slice of Phase 5 (Sync & Backend)** — 5a (foundation) + 5b (auth/transport) + 5c (sync engine) done; **5d makes sync feel live and observable, and closes the two deferred destructive behaviors.**

## 1. Purpose & scope
Make sync **feel instant and trustworthy**. Phase 5c made tasks flow both ways on launch / after-sign-in / manual "Sync Now"; 5d adds the layers that make it disappear into the background and become legible to the user:

- **Realtime (§7.6):** subscribe to the PocketBase `tasks` collection over SSE; apply remote create/update/delete to the local store within seconds, honoring LWW + device-local preservation + `device_id` echo-filtering.
- **Auto-cadence (§7.6):** a periodic safety-net sync (every 2 min while active), plus on-foreground and on-network-regained, coordinated through the existing single-flight engine.
- **Immediate debounced post-mutation push (§7.6):** a local edit uploads within ~1.5 s (coalesced), not on the next cadence tick.
- **Status surface (§7.7):** a quiet toolbar status chip (idle/syncing/pending/error/health) + Settings detail; pull-to-refresh.
- **Sync history (§7.7):** a persisted history table + a Sync History screen with summary stats.
- **Health monitoring (§7.7):** stale-queue / failed-item / token-expiry / reachability checks surfaced as non-alarming, actionable messaging.
- **Two deferred destructive behaviors (resolved 2026-06-02, owner chose to fold in with confirmations):** import-**replace** remote-deletion of cleared tasks, and **Erase All Data** remote wipe.

This is **one increment** (owner's call) — but the plan sequences its phases so the realtime/SSE risk, the destructive ops, and the observability UI are each independently buildable and verifiable. The §8.4(c) email-keyed identity (validated in 5b/5c, confirmed at the A64 gate) holds: a signed-in user's PocketBase records are the same set as the web app's.

**Out of scope (Phase 6+):** widgets / App-Intents / Share-Extension authenticated reads (Keychain access group); background-mode realtime (iOS forbids background polling — SSE is foreground-only by design); archive STATE sync (§7.1 has no `archived` column — archive stays device-local, unchanged from 5c); GitHub/Apple sign-in (later config).

## 2. Builds on (Phases 0–5c, on `main` at `phase-5c-sync-engine` / `4ea7218`)
- **`GSDSync`** (depends `GSDModel` + `GSDStore`): `SyncEngine` (`actor`: `sync(trigger:)` single-flight via `isSyncing`; `pull`/`seedExistingTasks`/`push`/`reconcileDeletions`/`resetCursor`; writes pulled tasks via `TaskRepository` directly — never re-stamps, never enqueues); `SyncResult`; `SyncTrigger {launch, signIn, manual}`; `SyncCursor` (`public`, App-Group ISO `lastSyncAt`, ±30 s overlap, `clear()` on sign-out); `PocketBaseClient` (`authedRequest(path:method:token:body:)` + `listTasks`/`remoteIndex`/`createTask`/`updateTask`/`deleteTask`); `TaskWireMapper.toDomain(_:mergingInto:)` (device-local-preserving merge) / `toWire`; `LWW.resolve`; `WireDate`; `JWT.userId`/`exp`; `AuthService.validToken()`.
- **`GSDStore`**: `SyncQueueItem` / `SyncQueueRepository` (`enqueue`/`pending()`/`update`/`remove`/`allTaskIds()`); `DeviceIdentity.current` (`deviceId`/`deviceName`); `TaskRepository` (`upsert`/`fetchAll`/`fetch(id:)`/`delete(id:)`/`replaceAll`/`observeAll`); `TaskStore` (`@MainActor @Observable`; mutations funnel through `repository` + `enqueue(...)`; `importTasks` merge/replace; `eraseAllData`); `AppDatabase` (GRDB migrations through **v4**); `AppGroupDefaults`/`StoreLocation.appGroupID`.
- **App**: `GSDApp` (constructs `store` + `session` + `syncEngine`; `.task` launch hook + `scenePhase` `onChange`); `SessionStore` (`@MainActor @Observable`; `signIn`/`signOut`/`syncNow`; currently holds `lastSync`/`syncing` — **5d moves those to `SyncCoordinator`**); `SettingsView` (Account section — `Sync Now` row); `DataStorageView` (export / import merge|replace / erase); `ContentView` (iPhone TabView, iPad NavigationSplitView).

## 3. Scope calls (design — approved in brainstorming)

### 3.1 Layering — thin coordinator (app), pure engine (GSDSync)
Lifecycle and UI state are app concerns; sync logic stays in the tested actor. This mirrors the existing `SessionStore`-wraps-`AuthService` precedent. An "engine owns timers + `NWPathMonitor`" variant was considered and **rejected** (wrong layer; a Foundation-only actor owning app-lifecycle timers is hard to unit-test and couples lifecycle semantics into the core).

- **`SyncCoordinator` (`@MainActor @Observable`, App layer)** — the single owner of *when* sync fires and *what status shows*:
  - the every-2-min cadence timer (runs only while `scenePhase == .active`),
  - `NWPathMonitor` reachability (network-regained → sync + SSE reconnect),
  - `scenePhase` reactions (foreground → `sync(.foreground)` + (re)start SSE + cadence; background → stop SSE + cancel timer),
  - the **debounced post-mutation push** (TaskStore signals a mutation → coalesce ~1.5 s → `engine.pushNow()`),
  - the **SSE subscription lifecycle** (start/stop/reconnect with backoff),
  - published status: `phase` (idle/syncing/error), `pendingCount`, `lastSync: SyncResult?`, `health: SyncHealth` — read by the chip + Settings.
- **`SessionStore`** keeps auth only (email/sign-in/out); on sign-in → `coordinator.start()`, on sign-out → `coordinator.stop()` + `engine.resetCursor()`. Its `lastSync`/`syncing`/`runSync` move to `SyncCoordinator` (avoids two types driving sync).

### 3.2 Engine additions (`GSDSync`, all unit-tested)
- **`applyRealtime(_ events:)`** — apply SSE record(s) by the **same rules as pull**: write via `TaskRepository` directly (no enqueue, no re-stamp), LWW vs local, `toDomain(_:mergingInto:)` device-local preserve. **Echo-filter:** skip a record **iff** `record.device_id == self.deviceId` *and* `device_id` is non-empty (empty/missing → foreign, apply). **Owner mismatch → skip.** **Malformed → skip** (never kill the stream). **Realtime delete** for a `task_id` with a **pending/failed queue item → skip** (queue-aware, same guard as `reconcileDeletions`; active-table-only). `delete` for an unknown/already-absent task is a no-op.
- **`pushNow() async -> SyncResult`** — push-only fast path: drain the queue (the existing `push` logic incl. LWW-guard / throttle / 429-abort / across-sync retry), **no pull / no reconcile**. Shares the single-flight `isSyncing` flag (a concurrent full `sync()` drops it, and vice-versa). Records history.
- **`eraseAllRemote() async -> SyncResult`** — see §3.4.
- **History recording** — at the end of each `sync()` and `pushNow()`, write a `SyncHistoryEntry` (§3.5). Read methods `recentHistory(limit:)` / `historyStats()` for the UI (GSDSync stays the single sync API surface).
- **New trigger cases** — `SyncTrigger` gains `foreground`, `periodic`, `networkRegained`, `mutation` (drives history `triggeredBy` + logging). `manual` (Sync Now / pull-to-refresh) and the new cases map to `user` / `auto` (§3.5).

### 3.3 Realtime (SSE) — `PocketBaseRealtime` (GSDSync, Foundation streaming)
- Parses the SSE line protocol (`id:` / `event:` / `data:` / blank-line dispatch; multi-line `data`) off `URLSession.bytes`, exposes decoded `{action, record}` events as an `AsyncStream`. The coordinator consumes; the engine applies.
- **Foreground-only.** Start on launch/foreground/sign-in; stop on background/sign-out. On reconnect/foreground, the coordinator runs a **full `sync()`** to catch events missed while disconnected (SSE is best-effort; the cadence + a foreground full-sync are the convergence guarantee).
- **Graceful degrade:** realtime is an *optimization, not a correctness requirement*. If SSE can't connect/subscribe, log and fall back to the 2-min cadence; retry SSE with backoff on foreground/network-regained.
- **⚠ Protocol is verify-at-gate (advisor point 1).** The PocketBase ≥0.23 realtime handshake is **recalled, not confirmed**: `GET /api/realtime` → `PB_CONNECT` event carrying a `clientId` → `POST /api/realtime` `{clientId, subscriptions:["tasks"|"tasks/*"]}` with the `Authorization` header → events `{action: create|update|delete, record: {...}}`; reconnect via `Last-Event-ID`. **Probe P1 (prerequisite, before any SSE code is written)** captures the real connect event, subscribe request shape, event envelope, and reconnect behavior from `api.vinny.io` into a record/replay fixture (the §7 "record/replay fixtures of PocketBase responses" mandate; same discipline as 5b's captured `auth-methods` and 5c's A64 list-shape check). Until P1 lands, the SSE client is specified against the above but treated as unconfirmed.

### 3.4 Destructive ops ordering guarantee (advisor point 2)
The hazard: erase-all / import-replace clear local tasks and enqueue deletes, but a concurrent `sync()`'s **pull** could re-add a just-cleared task before the deletes drain. Cursor-filtering prevents this for stale tasks (remote `client_updated_at` < cursor), but the **30 s overlap window** leaves a real gap for recently-edited tasks, and single-flight only drops the *second* caller — it doesn't guarantee *ours* wins.

**Guarantee — an in-engine `isErasing` gate.** While set, the `pull()` step **early-returns (no-op)**, so no concurrent sync can re-add.
- **Erase-all (`eraseAllRemote()`) — ALGORITHM REVISED during implementation (code-review fix, 2026-06-03):** instead of the originally-planned "enqueue a `.delete` for every local task → drain", erase now **authoritatively deletes every remote record from a FRESH `remoteIndex` (direct `deleteTask`, not via the queue), then clears the local queue**, under the `isErasing` gate. *Why:* the queue-based plan had a same-drain create-then-delete orphan race (a never-synced local task with a pending `.create` gets created, then its delete no-ops against the stale pre-loop index) and left stale `.update` items that resurrect tasks. Keying off the remote index is authoritative, avoids the race, clears stale ops, and also wipes remote-only tasks created on other devices. Returns an honest success/failure the App checks before clearing local. Signed-out → no-op.
- **Import-replace:** `TaskStore.importTasks(replace)` computes removed ids (present-before ∧ absent-after `replaceAll`), enqueues their `.delete`s (kept/added tasks enqueue `.update`/`.create` as today); the App calls `SyncCoordinator.flushAfterReplace()` → `engine.flushDeletes()` (gated push-only drain). `push()` now updates its in-memory index after each create, so a same-drain create-then-delete deletes the new record instead of orphaning it.
- **App orchestration (`SyncCoordinator.eraseEverywhere`):** wipes local **only when the remote wipe is confirmed** — signed-out, or a clean signed-in wipe; a single-flight skip (a cadence/SSE/debounced sync in-flight) is retried a few times, and a network failure leaves local intact (so tasks aren't wiped-locally-but-alive-remotely → re-pulled). Surfaces success/failure to the UI.
- **Offline tail (import-replace):** if the flush can't reach the network, the `.delete`s stay queued and the gate clears (scoped to the call, never persisted-stuck). The next online sync drains them; cursor-filtering means the stale remote records aren't re-pulled, and reconcile is queue-aware.
- **UI:** both get an explicit "This affects all your devices" confirmation in `DataStorageView` before invoking.

**Realtime apply is intentionally NOT single-flighted (decision, 2026-06-03):** `applyRealtime` does not take the `isSyncing` flag — adding it would make realtime drop events during every sync, defeating its purpose. The scary interleaving (a realtime delete during a `sync()` whose pre-fetched page re-adds the task) self-heals: `reconcileDeletions` runs last in the same `sync()` against a fresh index, so the worst case is a redundant write, never loss. Both paths are LWW-keyed. `applyRealtime` also skips a create/update when a local `.delete` is pending (no resurrection of a just-deleted task) and does **not** echo-filter deletes (a delete event carries the last *writer's* `device_id`, not the deleter's).

### 3.5 Sync history & health (§7.7)
- **`SyncHistoryEntry` / `syncHistory` table (GRDB migration v5):** `{ id, timestamp (ms), status (success|error|conflict|partial), pushedCount, pulledCount, conflictsResolved, failedCount?, errorMessage?, duration? (ms), deviceId, triggeredBy (user|auto) }`. `SyncHistoryRepository` (insert / recent(limit:) / stats / prune) — same pattern as the existing GRDB repos. Written by the engine at the end of each `sync()`/`pushNow()`; **realtime applies are NOT logged individually** (too noisy — the chip reflects them). `triggeredBy`: `manual` → `user`; `launch`/`signIn`/`foreground`/`periodic`/`networkRegained`/`mutation` → `auto`. Status: all-clean → `success`; some `failed` but progress made → `partial`; threw → `error`; (conflict counting reuses the LWW skip count). Keep a bounded history (prune beyond ~500).
- **`SyncHealth`** — a pure computed value from: stale queue items (> 1 h old), failed-item count, token expiry (`JWT.exp`), reachability (`NWPathMonitor`). Maps to a non-alarming, actionable message ("3 items haven't synced in over an hour — Retry"). Computed after each sync + on a light cadence.

### 3.6 Status UI (§7.7)
- **`SyncStatusChip`** (toolbar of the main screens — Matrix on iPhone, detail/sidebar on iPad): **hidden when idle**; syncing → spinner; pending > 0 → `↻N`; error/health-warning → amber `⚠`. Tapping navigates to Settings → Account. **Respects Reduce Motion** (static glyph, no spin — matches the app's existing reduce-motion convention).
- **Settings → Account detail:** "Synced <relative> · N pending", the existing `Sync Now`, a `Sync History ›` row, and any health message.
- **`SyncHistoryView`:** a `List` of recent entries (~50) + a summary header (total syncs, successes, total pushed, total pulled). Reads via the engine read methods.
- **Pull-to-refresh:** `.refreshable { await coordinator.syncNow() }` on the Matrix/Browse lists → `sync(.manual)`.

## 4. Feature groups (→ plan groups)
Sequenced so SSE risk, destructive ops, and UI are independently buildable/verifiable (advisor point 4).

- **A — History store + engine read/write + health (`GSDStore` + `GSDSync`, `swift test`):** v5 migration + `SyncHistoryEntry` + `SyncHistoryRepository`; engine writes history at end of `sync()`; `recentHistory`/`historyStats`; `SyncHealth` pure value. No behavior change yet — pure foundation.
- **B — Cadence + debounce + coordinator skeleton + status chip + pull-to-refresh (App, MANUAL + simctl):** `SyncCoordinator` (timer / `NWPathMonitor` / `scenePhase` / debounce); `engine.pushNow()` (push-only, unit-tested); move `lastSync`/`syncing` off `SessionStore`; `SyncStatusChip`; Settings detail; `SyncHistoryView`; `.refreshable`. **→ live checkpoint:** cadence + post-mutation push + chip work *without* SSE (cadence is the floor).
- **C — Realtime SSE (`GSDSync` + App, after Probe P1):** `PocketBaseRealtime` (SSE parser, fixture-tested); `engine.applyRealtime` (echo-filter / LWW / device-local / queue-aware delete, unit-tested); coordinator wires the stream; reconnect/foreground full-sync.
- **D — Destructive ops + confirmations (`GSDSync` + `GSDStore` + App):** `isErasing` gate + pull-suppression; `eraseAllRemote`; import-replace remote-deletion; `DataStorageView` confirmations.
- **Final:** combined spec+quality review → simctl smoke (both sims) → **live gate (L1–L7)** → merge/tag/push.

## 5. Testing
- **Unit (GSDSync/GSDStore, `swift test`):** `applyRealtime` (echo-filter own/empty/foreign `device_id`; LWW take/skip; device-local preserve; realtime-delete-with-pending-queue-item skip; owner-mismatch skip; malformed skip); `pushNow` (no pull/reconcile; single-flight; LWW guard); `eraseAllRemote` + import-replace (correct deletes enqueued; `isErasing` suppresses pull; drains); SSE line-parser (fixture streams; multi-line `data`; `PB_CONNECT`; reconnect); history recording (status derivation; `triggeredBy` mapping; stats); v5 migration round-trip; `SyncHealth` thresholds.
- **App-layer (MANUAL + simctl smoke, like `SessionStore`):** `SyncCoordinator` timer/scenePhase/reachability glue; chip rendering states; history screen; confirmations.
- **Probe P1 (prerequisite, before SSE code):** capture the real PocketBase realtime handshake/envelope from `api.vinny.io` (live token) → record/replay fixture. Run via `! curl …`; the plan provides the exact recipe.

## 6. Acceptance criteria (A65–A74)
- **A65** History: each `sync()`/`pushNow()` writes one `SyncHistoryEntry` with correct counts/status/`triggeredBy`; `recentHistory`/`historyStats` return them; v5 migration round-trips.
- **A66** `pushNow()` pushes pending items without pulling or reconciling; shares single-flight with `sync()`.
- **A67** Cadence: a 2-min periodic `sync()` fires only while active; foreground and network-regained each trigger a sync; concurrent triggers coalesce (single-flight drop).
- **A68** Debounced post-mutation push: a local edit triggers exactly one coalesced `pushNow()` ~1.5 s later.
- **A69** Status chip: hidden when idle; reflects syncing/pending-N/error; Reduce-Motion static; taps to Settings. Pull-to-refresh triggers `sync(.manual)`.
- **A70** Sync History screen lists recent entries + summary stats.
- **A71** Health: stale-queue (>1 h) / failed / token-expiry / offline each surface a non-alarming, actionable message.
- **A72** Realtime: `applyRealtime` applies foreign create/update/delete (LWW + device-local preserve), echo-filters own `device_id`, skips empty-`device_id`→apply, skips realtime-delete with a pending queue item, skips owner-mismatch/malformed.
- **A73** Destructive ops: import-replace enqueues deletes for cleared tasks and propagates remotely; `eraseAllRemote` wipes remote; `isErasing` suppresses a concurrent pull; both gated by a confirmation.
- **A74 (LIVE GATE — gates merge, two real devices/web):**
  - **L1** realtime create web→phone and phone→web within seconds (no manual sync).
  - **L2** realtime update + LWW both directions.
  - **L3** realtime delete propagates; echo-filter (own edits don't double-apply).
  - **L4** SSE reconnect on foreground catches events missed while backgrounded.
  - **L5** cadence safety-net (kill SSE → 2-min sync still converges) + network-regained reconnect.
  - **L6** erase-all wipes remote (web empties); import-replace propagates deletions. **Erase now keys off the remote index, so explicitly test a remote-only task:** create a task on device B → let it sync to the server → Erase-All on device A → confirm device B's task is ALSO wiped (not just locally-present tasks). Also: tap Erase while a sync is mid-flight → confirm it either completes or reports "try again" (never wipes local while remote survives).
  - **L7** chip states + pending count + health message; pull-to-refresh; history populated.
  - At the gate, confirm the realtime handshake/envelope (Probe P1) and the §7.5 PATCH null-vs-omit carry-forward.

## 7. Conventions (carried + new)
- **Carried:** `GSDModel` zero-dep; `GSDStore` never imports `GSDSync`; engine writes pulled/realtime tasks via the repo directly (no enqueue/re-stamp); cursor ISO in App-Group, ±30 s overlap, cleared on sign-out, local never wiped on sign-out; LWW on `client_updated_at`; push 429-abort + across-sync backoff (5/10/30/60/300 s) → `failed` after 5 (kept); `DEVELOPMENT_TEAM=52HVJ3VDSM` stays committed.
- **New:** SSE foreground-only + graceful-degrade-to-cadence; realtime echo-filter on non-empty `device_id`; `isErasing` pull-suppression gate for destructive ops; history written by the engine (single source of truth); realtime applies not logged individually; status UI is "quiet until it matters" + Reduce-Motion-aware.

## 8. Watch-outs
- **SSE protocol is unverified (§3.3):** do Probe P1 before coding the realtime client; write fixtures from observed bytes, not memory.
- **Destructive-op ordering (§3.4):** the `isErasing` gate must suppress `pull()` for the whole erase/replace window; never persist the gate stuck (offline tail relies on cursor-filtering + queue-aware reconcile).
- **Realtime delete vs pending queue item (§3.2):** honor the queue-aware guard — don't let a realtime delete drop a task the user just created locally and hasn't pushed.
- **Echo-filter empty `device_id`:** skip only on a *non-empty* match; an empty/missing `device_id` is foreign → apply (don't skip everything; web records may lack a `device_id`).
- **Single-flight is drop, not queue:** `pushNow()` and `sync()` share `isSyncing`; a debounced push during a full sync is dropped (cadence catches up) — by design.
- **No background polling:** SSE + cadence are foreground-only (iOS). BGAppRefresh (Phase 4) is separate and unaffected.
- **Coordinator/Session split:** moving `lastSync`/`syncing` to the coordinator must not regress the 5c after-sign-in / Sync-Now triggers — keep `SessionStore` delegating to the coordinator.
- **Archive STATE still does not sync** (§7.1 has no `archived` column) — unchanged; only active tasks and the now-destructive erase/replace flows are in scope.
- **Reduce Motion:** the chip's spinner must degrade to a static glyph (existing app convention).
