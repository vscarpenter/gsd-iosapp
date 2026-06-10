# Deferred Sync & Store Hardening — Design

**Date:** 2026-06-10
**Status:** Approved (owner, 2026-06-10)
**Context:** The pre-TestFlight audit (commit `a878f4f`) fixed the high-severity findings and
deferred five lower-frequency issues. This spec covers all five. Behavior authority remains
`spec.md`; §7.1 gets one wording update (Fix B, below).

One branch, five independently testable slices, implemented in risk order: E, D, A, B, C.

---

## Fix A — Reminder reconcile sweep (multi-device ghost/missing notifications)

**Problem:** Reminders are scheduled/cancelled only inside `TaskStore` mutations. Sync pull, SSE,
and deletion-reconcile write via the repository directly, so a task created on the iPad never
schedules a reminder on the iPhone, and a task completed/deleted remotely still fires its stale
reminder locally. The badge has the same blind spot (refreshed only on scenePhase changes).

**Design:** one new tested method on `TaskStore`:

```swift
/// Rebuild the reminder state from the live snapshot: cancel everything, re-schedule every
/// task that could plausibly fire, refresh the badge. Idempotent — schedule() uses stable
/// `task-<id>` identifiers, so re-scheduling replaces rather than duplicates.
public func resyncReminders() async {
    await reminders.cancelAll()
    for task in tasks where !task.completed && task.dueDate != nil && task.notificationEnabled {
        await reminders.schedule(task)
    }
    await refreshBadge()
}
```

The eligibility pre-filter (`dueDate != nil`, `!completed`, `notificationEnabled`) bounds the
notification-center IPC to reminder-bearing tasks; `schedule()` retains final say (quiet hours,
past-due → cancel) exactly as today.

**App wiring (GSDApp):** a `ReminderResyncer` mirroring `WidgetSnapshotRefresher` (≈1 s debounce),
fired from the existing `store.onTasksChanged` closure alongside `widgetRefresher.schedule()`,
plus one sweep in the launch `.task` (covers reminders lost if the app died mid-sweep).
Local edits trigger redundant sweeps — accepted; the sweep is idempotent.

**Rejected:** diff-based scheduling (track previously-scheduled ids). More state, more failure
modes, no user-visible benefit.

**Tests (GSDStore, `RecordingReminderScheduler`):** resync cancels all then schedules only
eligible tasks; completed/no-due/notification-disabled tasks are skipped; badge refreshed.

---

## Fix B — Clock-skew-proof pull cursor (server-stamped `updated`)

**Problem:** The pull filter is `client_updated_at >= cursor`, where `client_updated_at` is
stamped by whichever *device* wrote the record and the cursor advances from those same stamps.
A device whose clock runs more than the 30 s rewind behind its peers writes records that other
devices' cursors have already passed — those records are never pulled. Permanent, silent.

**Design:** the pull-completeness cursor moves to PocketBase's server-stamped `updated` system
field. **LWW conflict resolution stays on `client_updated_at`, unchanged** — §7.1's prohibition
on system timestamps exists to protect LWW, and LWW is untouched. Server stamps make device
clocks irrelevant to pull completeness.

Changes:

1. **`PocketBaseTaskRecord`** gains `updated: String` (snake-case key `updated`,
   `decodeIfPresent ?? ""` like every other defensive field). Encoding: PocketBase ignores
   client-sent system fields on write, so the synthesized encoder including it is harmless.
2. **`WireDate.parse`** accepts PocketBase's system-date variant — **space separator, not `T`**
   (`2026-06-10 12:00:00.123Z`). Normalize by replacing the first space with `T` before the
   existing lenient parse. New `WireDate.formatPocketBase(_:)` emits that same space form for
   filter strings.
3. **`listTasks`** filters and sorts on `updated` (`filter=updated >= "<cursor>"`,
   `sort=updated`). Confirm the filter accepts the space form at the live gate (precedent:
   the 5c filter-syntax confirmation).
4. **`SyncEngine.pull`** tracks `maxApplied` from each record's parsed `updated` (records whose
   `updated` fails to parse don't advance it; they still apply via LWW as today).
5. **`SyncCursor`** gets a new key `gsd.sync.lastServerUpdated` and a migration:
   - `load()`: return the new key if present; else, if the legacy `gsd.sync.lastSyncAt` exists,
     parse it (`WireDate`), subtract **24 h** (generous overlap — old client-time cursors are
     usually close to server time; re-pulls are idempotent via the LWW equal-ms no-op), and
     return it re-emitted via `formatPocketBase` so the filter always receives the space form.
     Else nil (first sync — seed runs, unchanged).
   - `advance(maxApplied:now:)`: write `formatPocketBase(maxApplied − 5 s)` to the new key and
     delete the legacy key. The `min(maxApplied, now)` clamp is **dropped** — it guarded against
     future *client* stamps, which server stamps can't produce; the 30 s rewind shrinks to 5 s
     (only same-second write overlap remains to cover).
   - `clear()` removes both keys.
6. **`spec.md` §7.1** wording update: system `created`/`updated` remain forbidden for *conflict
   resolution*; `updated` is now explicitly the *pull cursor* field (same update precedent as
   §3.4 in phase 5d).

Realtime (`applyRealtime`) never touched the cursor and still doesn't.

**Rejected:** widening the rewind window (e.g., −24 h on every sync) — shrinks the failure
window but any skew beyond it still loses data silently; wrong tool.

**Tests:** `WireDateTests` (space-form parse + `formatPocketBase` round-trip);
`SyncCursorTests` (new-key load, legacy-key −24 h fallback, advance writes new + deletes legacy,
clear removes both); `PocketBaseTaskListTests`/client tests (request path filters+sorts on
`updated`); `SyncEnginePullTests` (maxApplied derived from `updated`, unparseable `updated`
doesn't advance the cursor).

---

## Fix C — Cross-account sign-in prompt (merge or start fresh)

**Problem:** Sign-out keeps local tasks and clears the cursor; the next sign-in re-runs the
first-sync seed, silently uploading the *previous* account's tasks into the new account.

**Decision (owner):** prompt on a different-account sign-in.

**Design:**

- **`AuthService.currentUserId() -> String?`** (public): `tokenStore.load()` → `JWT.userId`.
- **Pure decision helper** in GSDSync (unit-tested):

  ```swift
  enum AccountSwitch {
      public enum Decision: Equatable { case proceed, prompt }
      public static func evaluate(lastOwnerId: String?, newOwnerId: String,
                                  hasLocalActiveTasks: Bool) -> Decision
      // .prompt iff lastOwnerId != nil && lastOwnerId != newOwnerId && hasLocalActiveTasks
  }
  ```

- **`SessionStore`** records the signed-in PocketBase user id (`result.record.id`) in
  `UserDefaults.standard` under `gsd.lastOwnerId` after every successful sign-in, and
  **backfills it at launch** (init: signed in + key absent → `auth.currentUserId()`), so
  existing installs get a baseline. `signOut()` does **not** clear it — remembering the
  previous owner is the whole point.
- **Flow on sign-in success** (both `signIn(provider:)` and `signInWithApple`): evaluate.
  `.proceed` → record owner + `coordinator.start(trigger: .signIn)` (today's behavior).
  `.prompt` → do **not** start the coordinator; set an observable
  `pendingAccountSwitch: PendingAccountSwitch?` (carries the new email for the dialog copy).
- **UI:** one `confirmationDialog` hosted at the `ContentView` root (covers sign-ins from both
  Settings and Onboarding), driven by `session.pendingAccountSwitch`:
  - **Keep my tasks** → `resolveAccountSwitch(.merge)`: record new owner, start coordinator
    (seed uploads local tasks — now with consent).
  - **Start fresh** (destructive role) → `resolveAccountSwitch(.fresh)`: `store.eraseAllData()`
    (local only — the new account's remote data is untouched), record new owner, start
    coordinator (empty seed, then pull brings the new account's tasks).
  - **Cancel** → `resolveAccountSwitch(.cancel)`: `signOut()` — no half-signed-in limbo where
    the UI says signed-in but sync is parked.
- SessionStore reaches the store via two injected closures (`hasLocalActiveTasks: () -> Bool`,
  `eraseLocal: () async throws -> Void`) following the coordinator's `signedIn` closure
  precedent — no `TaskStore` dependency added to SessionStore.

**No prompt when:** same account; first-ever sign-in (the §7.4 data-wipe-guard seed is the
designed behavior); zero active local tasks (archived tasks never sync, so they pose no
leakage; "start fresh" still erases them if chosen, which is what the user asked for).

**Tests:** `AccountSwitchTests` (pure decision matrix) + `AuthService.currentUserId` in GSDSync.
SessionStore/dialog glue is app-layer: build + manual gate (the SessionStore precedent).

---

## Fix D — Observer streams: bounded retry instead of silent freeze

**Problem:** The three `TaskStore` observers (`tasks`, `customViews`, `archivedTasks`) end with
`catch {}`. One thrown observation (transient I/O, one undecodable row) silently kills the
stream for the session: edits persist but the UI freezes.

**Design:** each observer becomes a retry loop — recreate the `ValueObservation` stream after a
1 s sleep, up to 5 consecutive failures, attempt counter reset on any successful emission; on
final give-up keep the last good snapshot (never blank the UI). The loop captures the
*repository* strongly (an immutable `let`) and `self` weakly, preserving today's
deinit-cancellation behavior.

**Rejected:** a "couldn't load tasks" UI surface — YAGNI; bounded retry covers the realistic
transient case invisibly, and a persistent failure here implies DB-level breakage that Fix
`liveWithRecovery` already addresses at next launch.

**Tests:** a fake `TaskRepository` whose `observeAll()` stream throws once then yields a
snapshot — assert `tasks` eventually populates (proves one retry). Existing observer tests prove
the happy path still works.

---

## Fix E — Close the reconcile race (transient delete of a just-created task)

**Problem:** `TaskStore` upserts, *then* enqueues; `reconcileDeletions` reads the queue, *then*
fetches tasks. The interleaving `upsert → queue-read → fetchAll → enqueue` sees the new task
with no queue protection and deletes it locally (self-heals on the next pull, but the user
watches a just-captured task vanish).

**Design — two coordinated changes that make protection provable:**

1. **`TaskStore` enqueues *before* it upserts** in every mutation path (`add`, `create`, `save`,
   `toggleComplete` + its recurrence spawn, `move`, `delete`, `snooze`, `startTimer`,
   `stopTimer`, `persist`, `restore`, `importTasks` both modes). Both writes serialize through
   the same GRDB writer, so: task visible to `fetchAll` ⟹ its upsert committed ⟹ its enqueue
   committed earlier. The private `enqueue` returns the queue-item id; if the subsequent upsert
   *throws*, the orphaned item is best-effort removed (`try? syncQueue.remove`) before
   rethrowing — an unpersisted task must not push a ghost create.
2. **`reconcileDeletions` reads `allTaskIds()` *after* `fetchAll()`** (swap two lines). Combined
   with (1): any task in the fetch snapshot is already in the later queue read. Window = zero.

Validation still precedes enqueue (an invalid task enqueues nothing). The push path is
unaffected — queue payloads are self-contained, so a debounced push racing the upsert is fine.

**Rejected:** a combined atomic upsert+enqueue repository method — equally correct but requires
a new cross-repository transaction API and touches every mutation path's persistence contract
for the same outcome.

**Tests:** repository fake whose `upsert` throws → assert the queue item was removed (cleanup
path); existing enqueue + reconcile suites prove ordering didn't break observable behavior.

---

## Non-goals

- No new UI beyond the account-switch dialog.
- No idempotency key for the share-extension outbox (accepted 6d risk, unchanged).
- No changes to LWW semantics, push, erase, or realtime protocols beyond the cursor source.

## Verification gates

`cd GSDKit && swift test` green; `xcodegen generate` (none of these touch `project.yml`, so
regenerate only if that changes); clean builds on iPhone 17 Pro + iPad Pro 13-inch (M5) sims.
Live two-device gate items for the owner (post-merge): pull filter on `updated` works against
the real PB instance (B); cross-account prompt + both resolutions (C); remote
complete/delete cancels the local reminder (A).
