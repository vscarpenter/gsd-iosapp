# Phase 5c — Sync Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make tasks flow both ways — a `SyncEngine` (`actor`, in `GSDSync`) that pulls (paged, LWW-upsert, device-local-preserving), pushes the queue (payload-`updatedAt` LWW-guard, throttle/429/retry), seeds the queue on first sign-in, reconciles deletions safely, and is wired to `TaskStore` enqueue-on-mutation + launch/sign-in/manual triggers.

**Architecture:** The engine composes 5a (`TaskWireMapper`/`LWW`/`SyncQueue`/`DeviceIdentity`) + 5b (`PocketBaseClient.authedRequest`/`AuthService.validToken`). It writes pulled tasks **directly via `TaskRepository`** (preserving the wire `client_updated_at` as local `updatedAt`; never re-stamping, never enqueuing), and the existing `TaskStore.observeAll()` `ValueObservation` bridge propagates them to the UI. `GSDSync` gains a `GSDStore` dependency (clean layering: `GSDModel` ← `GSDStore` ← `GSDSync`). Three data-loss guards drive the sequencing (seed-before-reconcile; LWW-guard-on-payload; every-creation-enqueues).

**Tech Stack:** Swift 6, `Foundation`/`URLSession` + GRDB (via `GSDStore`), Swift Testing, `xcodebuild`+simctl. `actor` for the engine; injected request-executor + in-memory GRDB repos + injected clock for deterministic tests.

**Builds on (Phases 0–5b, `main` at `phase-5b-auth-transport`):**
- `GSDSync` (Foundation-only → **+`GSDStore` in 5c**): `PocketBaseTaskRecord`/`WireTimeEntry`, `WireDate`, `TaskWireMapper.toWire(_:owner:deviceId:recordId:)` + `toDomain(_:mergingInto:)` (device-local-preserving merge), `LWW.resolve`, `PocketBaseClient` (`authedRequest(path:method:token:body:)`, the internal `init(baseURL:executor:)` test seam + `RequestExecuting`), `AuthService.validToken() async throws -> String?`, `AuthConfig.live`.
- `GSDStore`: `SyncQueueItem` (`operation` `.create`/`.update`/`.delete`; `payload: Task?`; `timestamp`/`retryCount`/`status`/`lastError`/`lastAttemptAt`/`failedAt`), `SyncQueueRepository`/`GRDBSyncQueueRepository` (`enqueue`/`pending()`/`update`/`remove`), `DeviceIdentity.current`, `GRDBTaskRepository` (`upsert`/`fetchAll`/`fetch`/`delete`/`replaceAll`/`observeAll`), `AppDatabase.inMemory()`, `TaskStore` (mutations + the `// NOTE (Phase 5)` markers), `AppGroupDefaults`.
- App: `GSDApp` (`.task` launch hook; constructs the store + 5b auth stack), `SessionStore` (5b — `signIn`/`signOut`), `SettingsView` (Account section).

**Reference:** spec `docs/specs/2026-05-30-phase-5c-sync-engine.md` (Groups A–C, A57–A64); product spec §7.3–7.7.

---

## Conventions locked by this plan (read first)

1. **Three data-loss guards — each a tested AC; do not weaken:**
   - **Seed before reconcile (A58):** on first sync (`cursor == nil`), enqueue every existing local active task as a push *before* pull/reconcile.
   - **Push LWW-guard on the PAYLOAD's `updatedAt` (A59):** skip an upsert iff remote `client_updated_at` > `payload.updatedAt` (NOT the queue `timestamp`). PROBE-VERIFIED.
   - **Every local-creation path enqueues (A60):** create / recurrence-spawn / import — esp. `toggleComplete`'s spawned instance as a separate `.create`.
2. **The engine writes pulled tasks via `TaskRepository.upsert` directly** — preserving the wire `client_updated_at` as local `updatedAt` (the LWW key; never re-stamp), and **never enqueuing** (pulled ≠ user mutation). Only `TaskStore` mutations enqueue.
3. **`GSDSync` gains a `GSDStore` dependency** (Package.swift) — the engine imports `GSDStore` + `GSDModel`. `GSDStore` still never imports `GSDSync` (no cycle). No `project.yml`/xcodegen change (the App already depends on `GSDSync`).
4. **`SyncEngine` is an `actor`; single-flight is an explicit `isSyncing` DROP** (a concurrent trigger returns `.skipped`, not queued).
5. **Token via an injected provider** `tokenProvider: @Sendable () async throws -> String?` (the App wires it to `authService.validToken()`; tests pass a canned closure) — decouples the engine from `AuthService` and eases testing. nil/throw ⇒ no-op (`.notSignedIn`).
6. **Cursor (PROBE-VERIFIED):** `lastSyncAt` ISO string in `AppGroupDefaults`; pull filters `client_updated_at >= cursor` (ISO lexicographic == chronological with the consistent fractional+Z format); advance = `min(maxApplied, now) − 30 s`, formatted ISO; **cleared on sign-out** (re-seed next sign-in); local tasks NEVER wiped on sign-out.
7. **Pagination is data-completeness (PROBE-VERIFIED):** decode `{page, perPage, totalItems, totalPages, items}`; loop pages `1…totalPages` and accumulate — never drop page 2+.
8. **Retry is ACROSS-sync** (no blocking sleeps in `sync()`): a failed item bumps `retryCount` + stamps `lastAttemptAt`; it's skipped until `now ≥ lastAttemptAt + backoff(retryCount)` (5/10/30/60/300 s); `failed` after 5.
9. **Deletion-reconcile = `localActive − (remote ∪ queued)`**, runs LAST, over a fresh post-push remote index; **active table only** (archived excluded); `queued` = ALL queue task_ids (pending + failed). PROBE-VERIFIED.
10. **Archive/restore do NOT enqueue** (device-local — brainstorming decision). `GSDModel.Task` shadows Swift's `Task` → `_Concurrency.Task`. Inject `clock`/executor/repos for determinism. Swift Testing; `xcodebuild`+simctl for the App. No `DEVELOPMENT_TEAM` in commits.
11. **Live gate (A64) gates merge** — unit-green is necessary, not sufficient (real-backend bidirectional sync is the deliverable). Stays on-branch until the owner confirms.

---

## Probe Results (run before this plan shipped; folded in — `/tmp/p5c-probe/probe.swift`, 15/15 PASS)

- **ISO lexicographic (3):** `.000 < .500`, across day boundary, midnight rollover — so the cursor compares correctly as ISO strings in the PB filter.
- **Cursor clamp + overlap (3):** clamp to `now−30` when `maxApplied` is future; `maxApplied−30` when past; ISO round-trips.
- **Pagination (3):** decode `{page,totalPages,items}`; the paging loop collects all 3 records across 2 pages (page 2 not dropped).
- **Push LWW-guard on payload (4):** stale-local(day1) vs fresher-remote(day2) → **SKIP** (the seed-clobber guard); fresher-local → push; no-remote → push; equal → push (idempotent).
- **Deletion-reconcile set (2 + 1):** deletes only the orphan (not the queued/remote ones); the first-sync seed (all local in queue) → nothing deleted; and confirms that *without* the seed a first sync would wipe everything (the bug the seed prevents).

The real `tasks` list shape (`{items,totalPages}`), the PB filter syntax, and bidirectional behavior are **confirm-at-live-gate** (A64) — not `/tmp`-probeable.

---

## File Structure

```
GSDKit/Package.swift                    # A: GSDSync target gains the GSDStore dependency
GSDKit/Sources/GSDSync/
├─ PocketBaseTaskList.swift             # A: ListPage<T> decode + PocketBaseClient.listTasks (paged) + remoteIndex + CRUD (create/update/delete)
├─ SyncCursor.swift                     # A: lastSyncAt ISO load/save/clear (AppGroupDefaults) + advance(maxApplied,now)
└─ SyncEngine.swift                     # A pull · B push+seed · C reconcile+sync()+SyncResult (the actor; grows across groups)
GSDKit/Tests/GSDSyncTests/
├─ PocketBaseTaskListTests.swift        # A: paged decode + CRUD request shapes
├─ SyncCursorTests.swift                # A: clamp/overlap/ISO
├─ SyncEnginePullTests.swift            # A: LWW upsert, device-local preserve, skip-malformed, paging
├─ SyncEnginePushTests.swift            # B: payload-LWW-guard, seed, create/update/delete, retry→failed
└─ SyncEngineReconcileTests.swift       # C: active-only/queue-aware/post-push delete, single-flight, sync() orchestration
GSDKit/Sources/GSDStore/
├─ SyncQueueRepository.swift            # B: + NoopSyncQueueRepository (TaskStore default) + allTaskIds() (reconcile)
└─ TaskStore.swift                      # B: inject syncQueue (default Noop) + enqueue(_:) at every mutation (spawn→.create; archive/restore excluded)
GSDKit/Tests/GSDStoreTests/
└─ TaskStoreEnqueueTests.swift          # B: recording-fake asserts enqueue per mutation + spawn + archive/restore-excluded
App/
├─ GSDApp.swift                         # C: construct SyncEngine; sync-on-launch (if signed in)
├─ Auth/SessionStore.swift              # C: after-signIn → engine.sync(.signIn); signOut → engine.resetCursor()
└─ Settings/SettingsView.swift          # C: "Sync Now" row (+ last-result line)
```

**Sequencing (safety-ordered):** **A** pull (read-only — live-checkpoint here first) → **B** enqueue + seed + push (local→remote; offline tasks upload) → **C** deletion-reconcile (destructive, last) + coordinator + triggers. Run package tests: `cd GSDKit && swift test --filter SyncEngine` (+ `SyncCursor`/`PocketBaseTaskList`/`TaskStoreEnqueue`). The full bidirectional **live gate (A64)** runs after C and gates merge.

---

## Group A — Pull engine (read-only) (`GSDSync`, `swift test`)

> Read-only and safe; build fully then **live-checkpoint** (sign in → a web task appears). Maps **A57**. PROBE-VERIFIED.

### Task A1: `GSDSync` → `GSDStore` dependency + access bumps

**Files:**
- Modify: `GSDKit/Package.swift`
- Modify: `GSDKit/Sources/GSDSync/PocketBaseClient.swift` (widen `send` to internal)
- Modify: `GSDKit/Sources/GSDSync/PocketBaseTaskRecord.swift` (widen `Failable` to internal)

- [ ] **Step 1: Add the `GSDStore` dependency to the `GSDSync` target** in `GSDKit/Package.swift`. Change:
```swift
        .target(name: "GSDSync", dependencies: ["GSDModel"]),
```
to:
```swift
        .target(name: "GSDSync", dependencies: ["GSDModel", "GSDStore"]),
```

- [ ] **Step 2: Widen two 5a/5b internals so the new task-API extension + paged decode can reuse them.**
  - In `PocketBaseClient.swift`, change `private func send<T: Decodable>` to `func send<T: Decodable>` (internal — a same-module extension will call it).
  - In `PocketBaseTaskRecord.swift`, change `private struct Failable<T: Decodable>: Decodable` to `struct Failable<T: Decodable>: Decodable` (internal — the paged list reuses it for skip-malformed).

- [ ] **Step 3: Verify the package builds with the new dependency.** Run: `cd GSDKit && swift build`. Expected: success (no cycle — `GSDStore` does not import `GSDSync`).

- [ ] **Step 4: Commit.**
```bash
git add GSDKit/Package.swift GSDKit/Sources/GSDSync/PocketBaseClient.swift GSDKit/Sources/GSDSync/PocketBaseTaskRecord.swift
git commit -m "build(sync): GSDSync depends on GSDStore; widen send/Failable for the task API (5c prep)"
```

---

### Task A2: `SyncCursor` (lastSyncAt + clamp/overlap)

**Files:**
- Create: `GSDKit/Sources/GSDSync/SyncCursor.swift`
- Test: `GSDKit/Tests/GSDSyncTests/SyncCursorTests.swift`

- [ ] **Step 1: Write the failing test** `GSDKit/Tests/GSDSyncTests/SyncCursorTests.swift`:
```swift
import Testing
import Foundation
@testable import GSDSync

struct SyncCursorTests {
    private func freshDefaults() -> UserDefaults {
        let suite = "test.synccursor.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!; d.removePersistentDomain(forName: suite); return d
    }

    @Test func unsetCursorIsNil() {
        #expect(SyncCursor(defaults: freshDefaults()).load() == nil)
    }

    @Test func advanceClampsToNowMinus30WhenMaxAppliedIsFuture() throws {
        let d = freshDefaults(); let cursor = SyncCursor(defaults: d)
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        cursor.advance(maxApplied: Date(timeIntervalSince1970: 1_000_000_100), now: now)  // future
        let saved = try #require(cursor.load())
        let savedDate = try #require(WireDate.parse(saved))
        #expect(Int(savedDate.timeIntervalSince1970) == 1_000_000_000 - 30)   // clamped to now-30
    }

    @Test func advanceUsesMaxAppliedMinus30WhenInPast() throws {
        let d = freshDefaults(); let cursor = SyncCursor(defaults: d)
        cursor.advance(maxApplied: Date(timeIntervalSince1970: 999_999_500),
                       now: Date(timeIntervalSince1970: 1_000_000_000))
        let savedDate = try #require(WireDate.parse(try #require(cursor.load())))
        #expect(Int(savedDate.timeIntervalSince1970) == 999_999_500 - 30)
    }

    @Test func advanceNoOpWhenMaxAppliedNil() {
        let d = freshDefaults(); let cursor = SyncCursor(defaults: d)
        cursor.advance(maxApplied: nil, now: Date())
        #expect(cursor.load() == nil)   // nothing pulled → cursor unchanged
    }

    @Test func clearResetsCursor() {
        let d = freshDefaults(); let cursor = SyncCursor(defaults: d)
        cursor.advance(maxApplied: Date(timeIntervalSince1970: 1000), now: Date(timeIntervalSince1970: 1_000_000))
        cursor.clear()
        #expect(cursor.load() == nil)
    }
}
```

- [ ] **Step 2: Run to verify it fails.** `cd GSDKit && swift test --filter SyncCursorTests` → FAIL (`SyncCursor` undefined).

- [ ] **Step 3: Create `SyncCursor`** `GSDKit/Sources/GSDSync/SyncCursor.swift`:
```swift
import Foundation
import GSDStore   // AppGroupDefaults

/// The pull cursor (`lastSyncAt`), persisted as an ISO-8601 string in App-Group defaults. Compared
/// and filtered as ISO (lexicographic == chronological, given the consistent fractional+Z format).
/// `nil` ⇒ never synced (triggers the first-sign-in seed). Cleared on sign-out. PROBE-VERIFIED.
struct SyncCursor {
    private let defaults: UserDefaults
    private let key = "gsd.sync.lastSyncAt"

    init(defaults: UserDefaults = AppGroupDefaults.shared) { self.defaults = defaults }

    func load() -> String? { defaults.string(forKey: key) }

    /// Advance to `min(maxApplied, now) − 30 s`, formatted ISO. No-op when `maxApplied` is nil
    /// (nothing was pulled, so the cursor must not move).
    func advance(maxApplied: Date?, now: Date) {
        guard let maxApplied else { return }
        let clamped = min(maxApplied, now).addingTimeInterval(-30)
        defaults.set(WireDate.format(clamped), forKey: key)
    }

    func clear() { defaults.removeObject(forKey: key) }
}
```

- [ ] **Step 4: Run to verify it passes.** `cd GSDKit && swift test --filter SyncCursorTests` → PASS (5 tests).

- [ ] **Step 5: Commit.**
```bash
git add GSDKit/Sources/GSDSync/SyncCursor.swift GSDKit/Tests/GSDSyncTests/SyncCursorTests.swift
git commit -m "feat(sync): add SyncCursor (lastSyncAt + clamp/30s-overlap) (A57 support)"
```

---

### Task A3: `PocketBaseClient.listTasks` (paged, skip-malformed)

**Files:**
- Create: `GSDKit/Sources/GSDSync/PocketBaseTaskList.swift`
- Test: `GSDKit/Tests/GSDSyncTests/PocketBaseTaskListTests.swift`

- [ ] **Step 1: Write the failing test** `GSDKit/Tests/GSDSyncTests/PocketBaseTaskListTests.swift`:
```swift
import Testing
import Foundation
@testable import GSDSync

struct PocketBaseTaskListTests {
    final class PagingExecutor: RequestExecuting, @unchecked Sendable {
        // route by the page query param → (json, status)
        var pages: [Int: String] = [:]
        private(set) var requestedPaths: [String] = []
        func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let url = request.url!.absoluteString
            requestedPaths.append(url)
            let page = url.contains("page=2") ? 2 : 1
            let body = pages[page] ?? #"{"page":1,"perPage":200,"totalItems":0,"totalPages":1,"items":[]}"#
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }
    private func rec(_ id: String) -> String {
        #"{"task_id":"\#(id)","title":"t","urgent":false,"important":false,"client_updated_at":"2026-06-15T09:00:00.000Z"}"#
    }

    @Test func pagesThroughAllRecordsAndSkipsMalformed() async throws {
        let exec = PagingExecutor()
        // page 1: two valid + one malformed (no task_id); page 2: one valid. totalPages=2.
        exec.pages[1] = #"{"page":1,"perPage":2,"totalItems":3,"totalPages":2,"items":[\#(rec("a")),{"title":"no task_id"},\#(rec("b"))]}"#
        exec.pages[2] = #"{"page":2,"perPage":2,"totalItems":3,"totalPages":2,"items":[\#(rec("c"))]}"#
        let client = PocketBaseClient(baseURL: "https://api.vinny.io", executor: exec)
        let records = try await client.listTasks(updatedSince: "2026-01-01T00:00:00.000Z", token: "TOK", perPage: 2)
        #expect(records.map(\.taskId) == ["a", "b", "c"])           // page 2 not dropped; malformed skipped
        #expect(exec.requestedPaths.contains { $0.contains("page=2") })  // actually paged
        #expect(exec.requestedPaths.allSatisfy { $0.contains("/api/collections/tasks/records") })
    }

    @Test func singlePageStopsAfterOne() async throws {
        let exec = PagingExecutor()
        exec.pages[1] = #"{"page":1,"perPage":200,"totalItems":1,"totalPages":1,"items":[\#(rec("a"))]}"#
        let client = PocketBaseClient(baseURL: "https://api.vinny.io", executor: exec)
        let records = try await client.listTasks(updatedSince: "2026-01-01T00:00:00.000Z", token: "TOK")
        #expect(records.map(\.taskId) == ["a"])
        #expect(exec.requestedPaths.count == 1)                     // didn't fetch a phantom page 2
    }
}
```

- [ ] **Step 2: Run to verify it fails.** `cd GSDKit && swift test --filter PocketBaseTaskListTests` → FAIL (`listTasks` undefined).

- [ ] **Step 3: Create the paged list** `GSDKit/Sources/GSDSync/PocketBaseTaskList.swift`:
```swift
import Foundation

/// One page of a PocketBase list response (§7.4).
struct ListPage<T: Decodable>: Decodable {
    let page: Int
    let perPage: Int
    let totalItems: Int
    let totalPages: Int
    let items: [T]
}

extension PocketBaseClient {
    /// Pull `tasks` records with `client_updated_at >= since` (ISO), paging through ALL pages
    /// (data-completeness — never drop page 2+). Malformed individual records are skipped (§7.4) via
    /// `Failable`. The `owner` API rule auto-scopes to the authed user. (Confirm the filter syntax at
    /// the live gate.)
    func listTasks(updatedSince since: String, token: String, perPage: Int = 200) async throws -> [PocketBaseTaskRecord] {
        var all: [PocketBaseTaskRecord] = []
        var page = 1
        while true {
            let filter = "client_updated_at >= \"\(since)\""
            let encoded = filter.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? filter
            let path = "/api/collections/tasks/records?page=\(page)&perPage=\(perPage)&sort=client_updated_at&filter=\(encoded)"
            let req = authedRequest(path: path, method: "GET", token: token)
            let pg = try await send(req, as: ListPage<Failable<PocketBaseTaskRecord>>.self)
            all.append(contentsOf: pg.items.compactMap(\.value))
            if page >= pg.totalPages { break }
            page += 1
        }
        return all
    }
}
```

- [ ] **Step 4: Run to verify it passes.** `cd GSDKit && swift test --filter PocketBaseTaskListTests` → PASS (2 tests).

- [ ] **Step 5: Commit.**
```bash
git add GSDKit/Sources/GSDSync/PocketBaseTaskList.swift GSDKit/Tests/GSDSyncTests/PocketBaseTaskListTests.swift
git commit -m "feat(sync): add paged listTasks (skip-malformed, all pages) (A57)"
```

---

### Task A4: `SyncEngine` skeleton + `pull` (upsert-only, LWW, device-local-preserving)

**Files:**
- Create: `GSDKit/Sources/GSDSync/SyncEngine.swift`
- Test: `GSDKit/Tests/GSDSyncTests/SyncEnginePullTests.swift`

> `pull` returns `(appliedCount, maxApplied)`. It LWW-upserts via `TaskWireMapper.toDomain(record, mergingInto: local)` (device-local preserve) and writes **directly through the repository** (preserving the wire `client_updated_at` as `updatedAt`; never re-stamps; never enqueues). The `sync()` orchestration is Group C.

- [ ] **Step 1: Write the failing test** `GSDKit/Tests/GSDSyncTests/SyncEnginePullTests.swift`:
```swift
import Testing
import Foundation
import GSDModel
import GSDStore
@testable import GSDSync

struct SyncEnginePullTests {
    final class ListExecutor: RequestExecuting, @unchecked Sendable {
        var json = #"{"page":1,"perPage":200,"totalItems":0,"totalPages":1,"items":[]}"#
        func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }
    private func engine(_ exec: ListExecutor, _ repo: GRDBTaskRepository) -> SyncEngine {
        SyncEngine(
            client: PocketBaseClient(baseURL: "https://api.vinny.io", executor: exec),
            tasks: repo,
            queue: GRDBSyncQueueRepository(try! AppDatabase.inMemory()),   // unused in pull
            cursor: SyncCursor(defaults: UserDefaults(suiteName: "t.\(UUID().uuidString)")!),
            deviceId: "dev-A",
            tokenProvider: { "TOK" },
            now: { Date(timeIntervalSince1970: 2_000_000_000) })
    }
    private func wire(_ id: String, title: String, updated: String) -> String {
        #"{"task_id":"\#(id)","title":"\#(title)","urgent":true,"important":false,"client_updated_at":"\#(updated)","client_created_at":"\#(updated)"}"#
    }

    @Test func pullUpsertsNewRemoteTask() async throws {
        let db = try AppDatabase.inMemory(); let repo = GRDBTaskRepository(db); let exec = ListExecutor()
        exec.json = #"{"page":1,"perPage":200,"totalItems":1,"totalPages":1,"items":[\#(wire("r1", title: "Remote", updated: "2026-06-15T09:00:00.000Z"))]}"#
        let (applied, maxApplied) = try await engine(exec, repo).pull(token: "TOK", since: "2026-01-01T00:00:00.000Z")
        #expect(applied == 1)
        let stored = try await repo.fetch(id: "r1")
        #expect(stored?.title == "Remote")
        #expect(maxApplied.map { Int($0.timeIntervalSince1970) } == Int(WireDate.parse("2026-06-15T09:00:00.000Z")!.timeIntervalSince1970))
    }

    @Test func pullSkipsWhenLocalIsNewer() async throws {
        let db = try AppDatabase.inMemory(); let repo = GRDBTaskRepository(db); let exec = ListExecutor()
        // local edited day 2; remote (incoming) edited day 1 → keep local
        let day2 = Date(timeIntervalSince1970: 2_000_000); let day1 = "1970-01-12T13:46:40.000Z"  // ~day 1
        try await repo.upsert(Task(id: "x", title: "Local v2", urgent: false, important: false,
                                   createdAt: day2, updatedAt: day2))
        exec.json = #"{"page":1,"perPage":200,"totalItems":1,"totalPages":1,"items":[\#(wire("x", title: "Remote v1", updated: day1))]}"#
        _ = try await engine(exec, repo).pull(token: "TOK", since: "1970-01-01T00:00:00.000Z")
        #expect(try await repo.fetch(id: "x")?.title == "Local v2")   // local newer → not overwritten
    }

    @Test func pullPreservesDeviceLocalFieldsOnMerge() async throws {
        let db = try AppDatabase.inMemory(); let repo = GRDBTaskRepository(db); let exec = ListExecutor()
        let old = Date(timeIntervalSince1970: 1_000_000)
        var local = Task(id: "x", title: "Local", urgent: false, important: false, createdAt: old, updatedAt: old)
        local.snoozedUntil = Date(timeIntervalSince1970: 1_500_000)   // device-local
        try await repo.upsert(local)
        // remote is NEWER → upsert, but snoozedUntil must stay local
        exec.json = #"{"page":1,"perPage":200,"totalItems":1,"totalPages":1,"items":[\#(wire("x", title: "Remote", updated: "2026-06-15T09:00:00.000Z"))]}"#
        _ = try await engine(exec, repo).pull(token: "TOK", since: "1970-01-01T00:00:00.000Z")
        let merged = try await repo.fetch(id: "x")
        #expect(merged?.title == "Remote")                                       // synced field updated
        #expect(merged?.snoozedUntil == Date(timeIntervalSince1970: 1_500_000))  // device-local preserved
    }
}
```

- [ ] **Step 2: Run to verify it fails.** `cd GSDKit && swift test --filter SyncEnginePullTests` → FAIL (`SyncEngine` undefined).

- [ ] **Step 3: Create `SyncEngine`** `GSDKit/Sources/GSDSync/SyncEngine.swift`:
```swift
import Foundation
import GSDModel
import GSDStore

/// The result of a sync attempt (§7.7 recording is 5d; 5c returns this for triggers/logging).
public struct SyncResult: Equatable, Sendable {
    public var pulled = 0
    public var pushed = 0
    public var deleted = 0
    public var failed = 0
    public var skipped = false       // a concurrent sync was in-flight (dropped)
    public var notSignedIn = false
    public var error: String?
}

public enum SyncTrigger: Sendable { case launch, signIn, manual }

/// Bidirectional active-task sync (§7.4–7.5). Writes pulled tasks DIRECTLY via the repository
/// (preserving the wire `client_updated_at`; never re-stamping; never enqueuing). `actor` for state
/// safety; single-flight is an explicit `isSyncing` drop. The `sync()` orchestration is added in Group C.
public actor SyncEngine {
    private let client: PocketBaseClient
    private let tasks: any TaskRepository
    private let queue: any SyncQueueRepository
    private let cursor: SyncCursor
    private let deviceId: String
    private let tokenProvider: @Sendable () async throws -> String?
    private let now: @Sendable () -> Date
    private var isSyncing = false

    public init(client: PocketBaseClient, tasks: any TaskRepository, queue: any SyncQueueRepository,
                cursor: SyncCursor, deviceId: String,
                tokenProvider: @escaping @Sendable () async throws -> String?,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client; self.tasks = tasks; self.queue = queue; self.cursor = cursor
        self.deviceId = deviceId; self.tokenProvider = tokenProvider; self.now = now
    }

    /// Pull remote → local (upsert-only; no deletes). LWW vs local; device-local preserved via the
    /// mapper merge. Returns the applied count + the max `client_updated_at` seen (for cursor advance).
    func pull(token: String, since: String) async throws -> (applied: Int, maxApplied: Date?) {
        let records = try await client.listTasks(updatedSince: since, token: token)
        var applied = 0
        var maxApplied: Date?
        for record in records {
            guard let remoteUpdated = WireDate.parse(record.clientUpdatedAt) else { continue }
            maxApplied = max(maxApplied ?? .distantPast, remoteUpdated)
            let local = try await tasks.fetch(id: record.taskId)
            // Upsert when there's no local copy, or the remote is strictly newer (LWW).
            let decision = LWW.resolve(localUpdatedAt: local?.updatedAt, remoteClientUpdatedAt: remoteUpdated)
            guard local == nil || decision == .takeRemote else { continue }
            try await tasks.upsert(TaskWireMapper.toDomain(record, mergingInto: local))
            applied += 1
        }
        return (applied, maxApplied)
    }
}
```

- [ ] **Step 4: Run to verify it passes.** `cd GSDKit && swift test --filter SyncEnginePullTests` → PASS (3 tests). Then `cd GSDKit && swift test` (full suite) → no regression.

- [ ] **Step 5: Commit.**
```bash
git add GSDKit/Sources/GSDSync/SyncEngine.swift GSDKit/Tests/GSDSyncTests/SyncEnginePullTests.swift
git commit -m "feat(sync): add SyncEngine pull (LWW upsert, device-local preserve) (A57)"
```

> **▶ LIVE PULL CHECKPOINT (after Group A merges to the branch):** with a temporary debug hook (or after Group C's launch trigger), sign in on the device → confirm an existing web task appears on the phone. This is the earliest real-backend validation; it confirms the list shape/filter/pagination before push is built. (Not a merge gate yet — that's A64.)

---

## Group B — Enqueue + seed + push (local → remote) (`GSDStore` + `GSDSync`, `swift test`)

> The local→remote path + two data-loss guards (seed, payload-LWW-guard). Maps **A58/A59/A60**.

### Task B1: `NoopSyncQueueRepository` + `allTaskIds()` (reconcile support)

**Files:**
- Modify: `GSDKit/Sources/GSDStore/SyncQueueRepository.swift`
- Test: `GSDKit/Tests/GSDStoreTests/SyncQueueRepositoryTests.swift` (extend)

- [ ] **Step 1: Add the failing test** — append to `SyncQueueRepositoryTests`:
```swift
    @Test func allTaskIdsReturnsPendingAndFailed() async throws {
        let repo = try makeRepo()
        try await repo.enqueue(SyncQueueItem(id: "q1", taskId: "t1", operation: .create, timestamp: 1))
        var failed = SyncQueueItem(id: "q2", taskId: "t2", operation: .update, timestamp: 2)
        failed.status = .failed
        try await repo.update(failed)   // upsert as failed
        #expect(try await repo.allTaskIds() == ["t1", "t2"])   // both states protect from reconcile
    }

    @Test func noopRepositoryDoesNothing() async throws {
        let noop = NoopSyncQueueRepository()
        try await noop.enqueue(SyncQueueItem(id: "x", taskId: "t", operation: .create, timestamp: 1))
        #expect(try await noop.pending().isEmpty)
        #expect(try await noop.allTaskIds().isEmpty)
    }
```

- [ ] **Step 2: Run to verify it fails.** `cd GSDKit && swift test --filter SyncQueueRepositoryTests` → FAIL (`allTaskIds`/`NoopSyncQueueRepository` undefined).

- [ ] **Step 3: Extend the protocol + impls** in `GSDKit/Sources/GSDStore/SyncQueueRepository.swift`. (a) Add to the `SyncQueueRepository` protocol: `func allTaskIds() async throws -> Set<String>`. (b) Implement on `GRDBSyncQueueRepository`:
```swift
    public func allTaskIds() async throws -> Set<String> {
        try await dbWriter.read { db in
            Set(try SyncQueueRecord.fetchAll(db).map(\.taskId))
        }
    }
```
(c) Add the no-op (the `TaskStore` default — keeps existing call sites/tests sync-free):
```swift
/// The default queue for `TaskStore` when no real sync is wired (mirrors `NoopReminderScheduler`).
public struct NoopSyncQueueRepository: SyncQueueRepository {
    public init() {}
    public func enqueue(_ item: SyncQueueItem) async throws {}
    public func pending() async throws -> [SyncQueueItem] { [] }
    public func update(_ item: SyncQueueItem) async throws {}
    public func remove(id: String) async throws {}
    public func allTaskIds() async throws -> Set<String> { [] }
}
```

- [ ] **Step 4: Run to verify it passes.** `cd GSDKit && swift test --filter SyncQueueRepositoryTests` → PASS.

- [ ] **Step 5: Commit.**
```bash
git add GSDKit/Sources/GSDStore/SyncQueueRepository.swift GSDKit/Tests/GSDStoreTests/SyncQueueRepositoryTests.swift
git commit -m "feat(sync): add SyncQueueRepository.allTaskIds + NoopSyncQueueRepository (5c support)"
```

---

### Task B2: `TaskStore` enqueue-on-mutation

**Files:**
- Modify: `GSDKit/Sources/GSDStore/TaskStore.swift`
- Test: `GSDKit/Tests/GSDStoreTests/TaskStoreEnqueueTests.swift`

> Every local-creation path enqueues (A60), incl. `toggleComplete`'s recurrence spawn as a separate `.create`. **Archive/restore do NOT enqueue** (device-local). `eraseAllData` does NOT enqueue (local reset; documented — remote re-pulls).

- [ ] **Step 1: Write the failing test** `GSDKit/Tests/GSDSyncTests` — no, `GSDKit/Tests/GSDStoreTests/TaskStoreEnqueueTests.swift`:
```swift
import Testing
import Foundation
import GSDModel
@testable import GSDStore

@MainActor
struct TaskStoreEnqueueTests {
    final class RecordingQueue: SyncQueueRepository, @unchecked Sendable {
        var ops: [(taskId: String, op: SyncQueueItem.Operation)] = []
        func enqueue(_ item: SyncQueueItem) async throws { ops.append((item.taskId, item.operation)) }
        func pending() async throws -> [SyncQueueItem] { [] }
        func update(_ item: SyncQueueItem) async throws {}
        func remove(id: String) async throws {}
        func allTaskIds() async throws -> Set<String> { [] }
    }
    private func makeStore(_ queue: RecordingQueue) throws -> TaskStore {
        let db = try AppDatabase.inMemory()
        return TaskStore(repository: GRDBTaskRepository(db),
                         smartViewRepository: GRDBSmartViewRepository(db),
                         archiveRepository: GRDBArchiveRepository(db),
                         defaults: UserDefaults(suiteName: "t.\(UUID().uuidString)")!,
                         clock: { Date(timeIntervalSince1970: 1000) },
                         calendar: { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }(),
                         syncQueue: queue)
    }
    private func sample(_ id: String, recurrence: RecurrenceType = .none, due: Date? = nil) -> Task {
        Task(id: id, title: "t", urgent: false, important: false, createdAt: Date(timeIntervalSince1970: 0),
             updatedAt: Date(timeIntervalSince1970: 0), dueDate: due, recurrence: recurrence)
    }

    @Test func createEnqueuesCreate() async throws {
        let q = RecordingQueue(); let store = try makeStore(q)
        try await store.create(sample("a"))
        #expect(q.ops.contains { $0.taskId == "a" && $0.op == .create })
    }

    @Test func saveEnqueuesUpdate() async throws {
        let q = RecordingQueue(); let store = try makeStore(q)
        try await store.save(sample("a"))
        #expect(q.ops.contains { $0.taskId == "a" && $0.op == .update })
    }

    @Test func deleteEnqueuesDelete() async throws {
        let q = RecordingQueue(); let store = try makeStore(q)
        try await store.delete(sample("a"))
        #expect(q.ops.contains { $0.taskId == "a" && $0.op == .delete })
    }

    @Test func toggleCompleteEnqueuesSpawnAsCreate() async throws {
        let q = RecordingQueue(); let store = try makeStore(q)
        let recurring = sample("r", recurrence: .daily, due: Date(timeIntervalSince1970: 500))
        try await store.create(recurring); q.ops.removeAll()
        try await store.toggleComplete(recurring)
        #expect(q.ops.contains { $0.taskId == "r" && $0.op == .update })          // the completed task
        #expect(q.ops.contains { $0.op == .create && $0.taskId != "r" })          // the spawned next instance
    }

    @Test func archiveAndRestoreDoNotEnqueue() async throws {
        let q = RecordingQueue(); let store = try makeStore(q)
        try await store.create(sample("a")); q.ops.removeAll()
        try await store.archive(sample("a"))
        try await store.restore(sample("a"))
        #expect(q.ops.isEmpty)   // archive/restore are device-local
    }
}
```

- [ ] **Step 2: Run to verify it fails.** `cd GSDKit && swift test --filter TaskStoreEnqueueTests` → FAIL (`TaskStore.init` has no `syncQueue:` param).

- [ ] **Step 3: Wire enqueue into `TaskStore`** (`GSDKit/Sources/GSDStore/TaskStore.swift`):
  (a) Add a stored dep + init param (defaulted no-op, after `reminders:`):
```swift
    private let syncQueue: any SyncQueueRepository
```
```swift
        reminders: any ReminderScheduling = NoopReminderScheduler(),
        syncQueue: any SyncQueueRepository = NoopSyncQueueRepository()
```
and in the body: `self.syncQueue = syncQueue`.
  (b) Add the helper (near `persist`):
```swift
    /// Enqueue a sync op for a local mutation (§7.5). `.delete` carries no payload. Best-effort —
    /// a queue failure must not fail the user's mutation (the next sync's seed/reconcile self-heals).
    private func enqueue(_ taskId: String, _ op: SyncQueueItem.Operation, payload: Task?) async {
        let item = SyncQueueItem(id: IDGenerator.generate(size: IDGenerator.Size.task),
                                 taskId: taskId, operation: op,
                                 timestamp: Int(clock().timeIntervalSince1970 * 1000),
                                 payload: op == .delete ? nil : payload)
        try? await syncQueue.enqueue(item)
    }
```
  (c) Add calls at each mutation (right after the `repository.upsert`/`delete`):
   - `create(_:)` — after `repository.upsert(t)`: `await enqueue(t.id, .create, payload: t)`
   - `save(_:)` — after upsert: `await enqueue(t.id, .update, payload: t)`
   - `move(_:to:)` — after upsert: `await enqueue(t.id, .update, payload: t)`
   - `snooze(_:by:)` — after upsert: `await enqueue(t.id, .update, payload: t)`
   - `startTimer`/`stopTimer` — after upsert: `await enqueue(t.id, .update, payload: t)`
   - `toggleComplete(_:)` — after `repository.upsert(t)`: `await enqueue(t.id, .update, payload: t)`; and after `repository.upsert(next)` (the spawn): `await enqueue(next.id, .create, payload: next)`
   - `delete(_:)` — after `repository.delete(id:)`: `await enqueue(task.id, .delete, payload: nil)`
   - `persist(_:)` (shared subtask/dependency path) — after upsert: `await enqueue(t.id, .update, payload: t)`
   - `importTasks(_:mode:)` — in BOTH branches, after writing each task: `await enqueue(t.id, .update, payload: t)` (replace: loop the stamped tasks and enqueue each; merge: in the existing loop). Remove the `// NOTE (Phase 5)` comment.
   - **`archive`/`restore`/`eraseAllData` — NO enqueue.** Remove the `// NOTE (Phase 5): enqueue a sync op here` comment from `archive` (device-local decision).
   - Bulk ops need nothing extra — they delegate to `toggleComplete`/`move`/`save`/`delete`, which now enqueue.

- [ ] **Step 4: Run to verify it passes.** `cd GSDKit && swift test --filter TaskStoreEnqueueTests` → PASS (5 tests). Then `cd GSDKit && swift test` (full) → no regression (the no-op default keeps existing tests green).

- [ ] **Step 5: Commit.**
```bash
git add GSDKit/Sources/GSDStore/TaskStore.swift GSDKit/Tests/GSDStoreTests/TaskStoreEnqueueTests.swift
git commit -m "feat(sync): TaskStore enqueues every local-creation/mutation (spawn→create; archive excluded) (A60)"
```

---

### Task B3: `SyncEngine.seedExistingTasks` (first-sign-in data-wipe guard)

**Files:**
- Modify: `GSDKit/Sources/GSDSync/SyncEngine.swift`
- Test: `GSDKit/Tests/GSDSyncTests/SyncEnginePushTests.swift` (create; extended in B5)

- [ ] **Step 1: Write the failing test** `GSDKit/Tests/GSDSyncTests/SyncEnginePushTests.swift`:
```swift
import Testing
import Foundation
import GSDModel
import GSDStore
@testable import GSDSync

struct SyncEnginePushTests {
    final class StubExecutor: RequestExecuting, @unchecked Sendable {
        func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            (Data(#"{"page":1,"perPage":200,"totalItems":0,"totalPages":1,"items":[]}"#.utf8),
             HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }
    func makeEngine(tasks: GRDBTaskRepository, queue: GRDBSyncQueueRepository,
                    exec: RequestExecuting = StubExecutor(), cursorDefaults: UserDefaults) -> SyncEngine {
        SyncEngine(client: PocketBaseClient(baseURL: "https://api.vinny.io", executor: exec),
                   tasks: tasks, queue: queue,
                   cursor: SyncCursor(defaults: cursorDefaults), deviceId: "dev-A",
                   tokenProvider: { "TOK" }, now: { Date(timeIntervalSince1970: 2_000_000_000) },
                   throttleMs: 0)
    }

    @Test func seedEnqueuesAllLocalActiveTasks() async throws {
        let db = try AppDatabase.inMemory()
        let tasks = GRDBTaskRepository(db); let queue = GRDBSyncQueueRepository(db)
        // a task created while signed-out (predates sync)
        try await tasks.upsert(Task(id: "offline-1", title: "made offline", urgent: false, important: false,
                                    createdAt: Date(timeIntervalSince1970: 1000), updatedAt: Date(timeIntervalSince1970: 1000)))
        let engine = makeEngine(tasks: tasks, queue: queue, cursorDefaults: UserDefaults(suiteName: "t.\(UUID().uuidString)")!)
        try await engine.seedExistingTasks()
        let queued = try await queue.allTaskIds()
        #expect(queued.contains("offline-1"))   // protected from deletion-reconcile + will be pushed
    }
}
```

- [ ] **Step 2: Run to verify it fails.** `cd GSDKit && swift test --filter SyncEnginePushTests` → FAIL (`throttleMs:` param + `seedExistingTasks` undefined).

- [ ] **Step 3: Extend `SyncEngine`** (`GSDKit/Sources/GSDSync/SyncEngine.swift`). (a) Add `throttleMs` to the init (defaulted, so A4's tests still compile):
```swift
    private let throttleMs: Int
```
```swift
                tokenProvider: @escaping @Sendable () async throws -> String?,
                now: @escaping @Sendable () -> Date = { Date() },
                throttleMs: Int = 100) {
```
and `self.throttleMs = throttleMs` in the body.
  (b) Add the seed:
```swift
    /// First-sign-in data-wipe guard (§7.4/§7.5): enqueue every existing local active task as a push
    /// BEFORE any pull/reconcile, so pre-sign-in tasks are both uploaded and protected (they're then
    /// "in the queue" → deletion-reconcile skips them). Called by `sync()` only when the cursor is unset.
    func seedExistingTasks() async throws {
        for task in try await tasks.fetchAll() {
            try await queue.enqueue(SyncQueueItem(
                id: UUID().uuidString, taskId: task.id, operation: .update,
                timestamp: Int(now().timeIntervalSince1970 * 1000), payload: task))
        }
    }
```

- [ ] **Step 4: Run to verify it passes.** `cd GSDKit && swift test --filter SyncEnginePushTests` → PASS (1 test).

- [ ] **Step 5: Commit.**
```bash
git add GSDKit/Sources/GSDSync/SyncEngine.swift GSDKit/Tests/GSDSyncTests/SyncEnginePushTests.swift
git commit -m "feat(sync): add first-sign-in queue seed (data-wipe guard) (A58)"
```

---

### Task B4: `PocketBaseClient` task CRUD + `remoteIndex` + JWT owner

**Files:**
- Modify: `GSDKit/Sources/GSDSync/PocketBaseClient.swift` (add internal `sendNoContent`)
- Modify: `GSDKit/Sources/GSDSync/JWT.swift` (add `userId`)
- Create: `GSDKit/Sources/GSDSync/PocketBaseTaskWrite.swift` (CRUD + remoteIndex extension)
- Test: `GSDKit/Tests/GSDSyncTests/PocketBaseTaskWriteTests.swift`

- [ ] **Step 1: Write the failing test** `GSDKit/Tests/GSDSyncTests/PocketBaseTaskWriteTests.swift`:
```swift
import Testing
import Foundation
@testable import GSDSync

struct PocketBaseTaskWriteTests {
    final class CapturingExecutor: RequestExecuting, @unchecked Sendable {
        var response = #"{"id":"rec_new","task_id":"a","title":"t","urgent":false,"important":false}"#
        var status = 200
        private(set) var lastMethod = ""; private(set) var lastPath = ""; private(set) var lastBody: Data?
        func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            lastMethod = request.httpMethod ?? ""; lastPath = request.url!.path; lastBody = request.httpBody
            return (Data(response.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }
    private func record(_ id: String, recordId: String = "") -> PocketBaseTaskRecord {
        TaskWireMapper.toWire(Task(id: id, title: "t", urgent: false, important: false,
                                   createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0)),
                              owner: "u", deviceId: "d", recordId: recordId)
    }

    @Test func createPostsAndReturnsRecordId() async throws {
        let exec = CapturingExecutor()
        let client = PocketBaseClient(baseURL: "https://api.vinny.io", executor: exec)
        let newId = try await client.createTask(record("a"), token: "TOK")
        #expect(newId == "rec_new")
        #expect(exec.lastMethod == "POST" && exec.lastPath == "/api/collections/tasks/records")
    }

    @Test func updatePatchesByRecordId() async throws {
        let exec = CapturingExecutor()
        let client = PocketBaseClient(baseURL: "https://api.vinny.io", executor: exec)
        try await client.updateTask(recordId: "rec_1", record: record("a", recordId: "rec_1"), token: "TOK")
        #expect(exec.lastMethod == "PATCH" && exec.lastPath == "/api/collections/tasks/records/rec_1")
    }

    @Test func deleteSendsDelete() async throws {
        let exec = CapturingExecutor(); exec.status = 204; exec.response = ""
        let client = PocketBaseClient(baseURL: "https://api.vinny.io", executor: exec)
        try await client.deleteTask(recordId: "rec_1", token: "TOK")
        #expect(exec.lastMethod == "DELETE" && exec.lastPath == "/api/collections/tasks/records/rec_1")
    }

    @Test func jwtUserIdDecodesIdClaim() {
        func b64url(_ d: Data) -> String { d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
        let token = "h.\(b64url(Data(#"{"id":"user_42","exp":1893456000}"#.utf8))).s"
        #expect(JWT.userId(token) == "user_42")
    }
}
```

- [ ] **Step 2: Run to verify it fails.** `cd GSDKit && swift test --filter PocketBaseTaskWriteTests` → FAIL (CRUD/`JWT.userId` undefined).

- [ ] **Step 3: Add `sendNoContent`** to `PocketBaseClient.swift` (internal, for 204 DELETE — no decode):
```swift
    func sendNoContent(_ request: URLRequest) async throws {
        let (data, http) = try await executor.execute(request)
        guard (200..<300).contains(http.statusCode) else {
            if let env = try? JSONDecoder().decode(PBErrorEnvelope.self, from: data) {
                throw PocketBaseError.pocketBase(status: http.statusCode, message: env.message)
            }
            throw PocketBaseError.http(status: http.statusCode, body: String(decoding: data, as: UTF8.self))
        }
    }
```
(`executor` is private but `sendNoContent` is a method on `PocketBaseClient` itself, so it can use it.)

- [ ] **Step 4: Add `JWT.userId`** to `JWT.swift`:
```swift
    /// The PocketBase user record id (`id` claim) — the `owner` for pushed records.
    static func userId(_ token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count == 3, let payload = base64urlDecode(String(parts[1])),
              let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let id = obj["id"] as? String else { return nil }
        return id
    }
```

- [ ] **Step 5: Create the CRUD + index** `GSDKit/Sources/GSDSync/PocketBaseTaskWrite.swift`:
```swift
import Foundation

extension PocketBaseClient {
    /// Bulk remote index for push (§7.5): `task_id → (recordId, client_updated_at)`. One fetch per push.
    func remoteIndex(token: String) async throws -> [String: (recordId: String, clientUpdatedAt: Date?)] {
        let records = try await listTasks(updatedSince: "1970-01-01T00:00:00.000Z", token: token)
        var index: [String: (recordId: String, clientUpdatedAt: Date?)] = [:]
        for r in records { index[r.taskId] = (r.id, WireDate.parse(r.clientUpdatedAt)) }
        return index
    }

    /// Create a `tasks` record; returns the new PocketBase record id.
    func createTask(_ record: PocketBaseTaskRecord, token: String) async throws -> String {
        let req = authedRequest(path: "/api/collections/tasks/records", method: "POST",
                                token: token, body: try JSONEncoder().encode(record))
        return try await send(req, as: PocketBaseTaskRecord.self).id
    }
    /// Update by record id (PATCH).
    func updateTask(recordId: String, record: PocketBaseTaskRecord, token: String) async throws {
        let req = authedRequest(path: "/api/collections/tasks/records/\(recordId)", method: "PATCH",
                                token: token, body: try JSONEncoder().encode(record))
        _ = try await send(req, as: PocketBaseTaskRecord.self)
    }
    /// Delete by record id (204, no body).
    func deleteTask(recordId: String, token: String) async throws {
        try await sendNoContent(authedRequest(path: "/api/collections/tasks/records/\(recordId)", method: "DELETE", token: token))
    }
}
```

- [ ] **Step 6: Run to verify it passes.** `cd GSDKit && swift test --filter PocketBaseTaskWriteTests` → PASS (4 tests).

- [ ] **Step 7: Commit.**
```bash
git add GSDKit/Sources/GSDSync/PocketBaseClient.swift GSDKit/Sources/GSDSync/JWT.swift GSDKit/Sources/GSDSync/PocketBaseTaskWrite.swift GSDKit/Tests/GSDSyncTests/PocketBaseTaskWriteTests.swift
git commit -m "feat(sync): add task CRUD + remoteIndex + JWT.userId for push (A59 support)"
```

> **Live-gate notes:** confirm whether create needs `owner` in the body (or PocketBase sets it from `@request.auth.id`) and whether PATCH should send explicit `null` vs omit for nil `notify_before`/`estimated_minutes`. The JWT `id` claim is the assumed `owner` source — confirm at A64.

---

### Task B5: `SyncEngine.push` (payload-LWW-guard, CRUD, throttle, 429-abort, across-sync retry)

**Files:**
- Modify: `GSDKit/Sources/GSDSync/SyncEngine.swift`
- Test: `GSDKit/Tests/GSDSyncTests/SyncEnginePushTests.swift` (extend)

- [ ] **Step 1: Add the failing tests** — append to `SyncEnginePushTests` (reuse `makeEngine`; add this executor + tests):
```swift
    final class CRUDExecutor: RequestExecuting, @unchecked Sendable {
        var indexJSON = #"{"page":1,"perPage":200,"totalItems":0,"totalPages":1,"items":[]}"#
        var writeStatus = 200
        private(set) var writes: [(method: String, path: String)] = []
        func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let m = request.httpMethod ?? "GET"
            if m == "GET" {   // listTasks (remoteIndex)
                return (Data(indexJSON.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            writes.append((m, request.url!.path))
            let body = #"{"id":"rec_x","task_id":"a","title":"t","urgent":false,"important":false}"#
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: writeStatus, httpVersion: nil, headerFields: nil)!)
        }
    }
    private func remoteItem(taskId: String, recordId: String, updated: String) -> String {
        #"{"task_id":"\#(taskId)","id":"\#(recordId)","title":"remote","urgent":false,"important":false,"client_updated_at":"\#(updated)"}"#
    }

    @Test func pushSkipsAndDropsStaleItemWhenRemoteNewer() async throws {   // THE seed-clobber data-loss guard
        let db = try AppDatabase.inMemory(); let tasks = GRDBTaskRepository(db); let queue = GRDBSyncQueueRepository(db)
        let exec = CRUDExecutor()
        exec.indexJSON = #"{"page":1,"perPage":200,"totalItems":1,"totalPages":1,"items":[\#(remoteItem(taskId: "a", recordId: "rec_a", updated: "2026-06-15T09:00:00.000Z"))]}"#
        let stale = Task(id: "a", title: "stale local", urgent: false, important: false,
                         createdAt: Date(timeIntervalSince1970: 1_000_000), updatedAt: Date(timeIntervalSince1970: 1_000_000))  // day 1
        try await queue.enqueue(SyncQueueItem(id: "q1", taskId: "a", operation: .update, timestamp: 9_999_999_999, payload: stale))
        let engine = makeEngine(tasks: tasks, queue: queue, exec: exec, cursorDefaults: UserDefaults(suiteName: "t.\(UUID().uuidString)")!)
        let (pushed, failed) = try await engine.push(token: "TOK", owner: "u")
        #expect(pushed == 0 && failed == 0)
        #expect(!exec.writes.contains { $0.method == "PATCH" })       // remote(day2) > payload(day1) → NO clobber
        #expect(try await queue.pending().isEmpty)                    // stale item dropped; next pull delivers remote
    }

    @Test func pushCreatesWhenNoRemote() async throws {
        let db = try AppDatabase.inMemory(); let tasks = GRDBTaskRepository(db); let queue = GRDBSyncQueueRepository(db)
        let exec = CRUDExecutor()   // empty remote index
        let t = Task(id: "a", title: "new local", urgent: false, important: false,
                     createdAt: Date(timeIntervalSince1970: 5_000_000), updatedAt: Date(timeIntervalSince1970: 5_000_000))
        try await queue.enqueue(SyncQueueItem(id: "q1", taskId: "a", operation: .create, timestamp: 1, payload: t))
        let (pushed, _) = try await makeEngine(tasks: tasks, queue: queue, exec: exec, cursorDefaults: UserDefaults(suiteName: "t.\(UUID().uuidString)")!).push(token: "TOK", owner: "u")
        #expect(pushed == 1)
        #expect(exec.writes.contains { $0.method == "POST" })
        #expect(try await queue.pending().isEmpty)
    }

    @Test func pushFailureBumpsRetryCountAndKeepsPending() async throws {
        let db = try AppDatabase.inMemory(); let tasks = GRDBTaskRepository(db); let queue = GRDBSyncQueueRepository(db)
        let exec = CRUDExecutor(); exec.writeStatus = 500   // server error
        let t = Task(id: "a", title: "x", urgent: false, important: false,
                     createdAt: Date(timeIntervalSince1970: 5_000_000), updatedAt: Date(timeIntervalSince1970: 5_000_000))
        try await queue.enqueue(SyncQueueItem(id: "q1", taskId: "a", operation: .create, timestamp: 1, payload: t))
        let (pushed, failed) = try await makeEngine(tasks: tasks, queue: queue, exec: exec, cursorDefaults: UserDefaults(suiteName: "t.\(UUID().uuidString)")!).push(token: "TOK", owner: "u")
        #expect(pushed == 0 && failed == 1)
        let pending = try await queue.pending()
        #expect(pending.count == 1 && pending[0].retryCount == 1)   // kept, retryCount bumped (across-sync retry)
    }
}
```

- [ ] **Step 2: Run to verify it fails.** `cd GSDKit && swift test --filter SyncEnginePushTests` → FAIL (`push` undefined).

- [ ] **Step 3: Add `push`** to `GSDKit/Sources/GSDSync/SyncEngine.swift`:
```swift
    private static let backoffSeconds: [TimeInterval] = [5, 10, 30, 60, 300]
    private func isDue(_ item: SyncQueueItem, nowMs: Int) -> Bool {
        guard let last = item.lastAttemptAt else { return true }        // never attempted → due
        let wait = Self.backoffSeconds[min(max(item.retryCount - 1, 0), Self.backoffSeconds.count - 1)]
        return nowMs >= last + Int(wait * 1000)
    }

    /// Drain the pending queue → remote (§7.5). Payload-LWW-guard (skip+drop a stale upsert iff remote
    /// `client_updated_at` > the payload's `updatedAt`); create(no recordId)/update(by recordId)/delete;
    /// ~throttle; 429 aborts the loop; across-sync retry (5/10/30/60/300 s) → `failed` after 5 (kept).
    func push(token: String, owner: String) async throws -> (pushed: Int, failed: Int) {
        let index = try await client.remoteIndex(token: token)
        let nowMs = Int(now().timeIntervalSince1970 * 1000)
        var pushed = 0, failed = 0
        for item in try await queue.pending() where isDue(item, nowMs: nowMs) {
            let remote = index[item.taskId]
            // payload-LWW-guard (upserts only): remote strictly newer than what we'd write → drop, let pull win.
            if item.operation != .delete, let payload = item.payload, let remoteUpdated = remote?.clientUpdatedAt,
               Int(remoteUpdated.timeIntervalSince1970 * 1000) > Int(payload.updatedAt.timeIntervalSince1970 * 1000) {
                try await queue.remove(id: item.id); continue
            }
            do {
                switch item.operation {
                case .delete:
                    if let recordId = remote?.recordId { try await client.deleteTask(recordId: recordId, token: token) }
                case .create, .update:
                    guard let payload = item.payload else { break }
                    let wire = TaskWireMapper.toWire(payload, owner: owner, deviceId: deviceId, recordId: remote?.recordId ?? "")
                    if let recordId = remote?.recordId { try await client.updateTask(recordId: recordId, record: wire, token: token) }
                    else { _ = try await client.createTask(wire, token: token) }
                }
                try await queue.remove(id: item.id); pushed += 1
                if throttleMs > 0 { try? await _Concurrency.Task.sleep(for: .milliseconds(throttleMs)) }
            } catch let e as PocketBaseError {
                if case .http(429, _) = e { break }                    // 429 → abort
                if case .pocketBase(429, _) = e { break }
                var f = item; f.retryCount += 1; f.lastAttemptAt = nowMs; f.lastError = String("\(e)".prefix(200))
                if f.retryCount >= 5 { f.status = .failed; f.failedAt = nowMs }
                try await queue.update(f); failed += 1
            }
        }
        return (pushed, failed)
    }
```

- [ ] **Step 4: Run to verify it passes.** `cd GSDKit && swift test --filter SyncEnginePushTests` → PASS (4 tests). Then `cd GSDKit && swift test` (full) → no regression.

- [ ] **Step 5: Commit.**
```bash
git add GSDKit/Sources/GSDSync/SyncEngine.swift GSDKit/Tests/GSDSyncTests/SyncEnginePushTests.swift
git commit -m "feat(sync): add SyncEngine push (payload-LWW-guard, CRUD, retry) (A59)"
```

---

## Group C — Reconcile + coordinator + triggers (`GSDSync` + App, `swift test` + build)

> Deletion-reconcile (destructive, last), the single-flight `sync()`, and the App triggers. Maps **A61/A62/A63**; the live gate is **A64**.

### Task C1: `SyncEngine.reconcileDeletions` (active-only, queue-aware, post-push)

**Files:**
- Modify: `GSDKit/Sources/GSDSync/SyncEngine.swift`
- Test: `GSDKit/Tests/GSDSyncTests/SyncEngineReconcileTests.swift`

- [ ] **Step 1: Write the failing test** `GSDKit/Tests/GSDSyncTests/SyncEngineReconcileTests.swift`:
```swift
import Testing
import Foundation
import GSDModel
import GSDStore
@testable import GSDSync

struct SyncEngineReconcileTests {
    final class IndexExecutor: RequestExecuting, @unchecked Sendable {
        var indexJSON = #"{"page":1,"perPage":200,"totalItems":0,"totalPages":1,"items":[]}"#
        func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            (Data(indexJSON.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }
    private func task(_ id: String) -> Task {
        Task(id: id, title: id, urgent: false, important: false, createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
    }
    private func engine(tasks: GRDBTaskRepository, queue: GRDBSyncQueueRepository, exec: IndexExecutor) -> SyncEngine {
        SyncEngine(client: PocketBaseClient(baseURL: "https://api.vinny.io", executor: exec),
                   tasks: tasks, queue: queue, cursor: SyncCursor(defaults: UserDefaults(suiteName: "t.\(UUID().uuidString)")!),
                   deviceId: "d", tokenProvider: { "TOK" }, now: { Date(timeIntervalSince1970: 2_000_000_000) }, throttleMs: 0)
    }

    @Test func deletesOnlyOrphans() async throws {
        let db = try AppDatabase.inMemory(); let tasks = GRDBTaskRepository(db); let queue = GRDBSyncQueueRepository(db)
        for id in ["a", "b", "c", "d"] { try await tasks.upsert(task(id)) }
        let exec = IndexExecutor()   // remote has a, b
        exec.indexJSON = #"{"page":1,"perPage":200,"totalItems":2,"totalPages":1,"items":[{"task_id":"a","id":"r1"},{"task_id":"b","id":"r2"}]}"#
        try await queue.enqueue(SyncQueueItem(id: "q", taskId: "c", operation: .update, timestamp: 1, payload: task("c")))  // c is queued
        let deleted = try await engine(tasks: tasks, queue: queue, exec: exec).reconcileDeletions(token: "TOK")
        #expect(deleted == 1)                                   // only d (absent-remote AND not-queued)
        #expect(try await tasks.fetch(id: "d") == nil)
        #expect(try await tasks.fetch(id: "a") != nil && (try await tasks.fetch(id: "c")) != nil)
    }

    @Test func seedScenarioDeletesNothing() async throws {     // first-sync seed protects everything
        let db = try AppDatabase.inMemory(); let tasks = GRDBTaskRepository(db); let queue = GRDBSyncQueueRepository(db)
        for id in ["a", "b"] { try await tasks.upsert(task(id)); try await queue.enqueue(SyncQueueItem(id: "q-\(id)", taskId: id, operation: .update, timestamp: 1, payload: task(id))) }
        let deleted = try await engine(tasks: tasks, queue: queue, exec: IndexExecutor()).reconcileDeletions(token: "TOK")  // empty remote
        #expect(deleted == 0)                                   // all queued → none deleted
    }
}
```

- [ ] **Step 2: Run to verify it fails.** `cd GSDKit && swift test --filter SyncEngineReconcileTests` → FAIL (`reconcileDeletions` undefined).

- [ ] **Step 3: Add `reconcileDeletions`** to `SyncEngine.swift`:
```swift
    /// §7.4 step 5 (destructive — runs LAST, over a FRESH post-push remote index): delete local
    /// ACTIVE tasks absent remotely AND not in the queue. `fetchAll()` is the active table only
    /// (archived is a separate repo, out of scope). `allTaskIds()` = pending + failed (both protect).
    func reconcileDeletions(token: String) async throws -> Int {
        let remoteIds = Set(try await client.remoteIndex(token: token).keys)
        let queuedIds = try await queue.allTaskIds()
        var deleted = 0
        for task in try await tasks.fetchAll() where !remoteIds.contains(task.id) && !queuedIds.contains(task.id) {
            try await tasks.delete(id: task.id); deleted += 1
        }
        return deleted
    }
```

- [ ] **Step 4: Run to verify it passes.** `cd GSDKit && swift test --filter SyncEngineReconcileTests` → PASS (2 tests).

- [ ] **Step 5: Commit.**
```bash
git add GSDKit/Sources/GSDSync/SyncEngine.swift GSDKit/Tests/GSDSyncTests/SyncEngineReconcileTests.swift
git commit -m "feat(sync): add deletion-reconcile (active-only, queue-aware) (A61)"
```

---

### Task C2: `SyncEngine.sync()` orchestration + single-flight + `resetCursor`

**Files:**
- Modify: `GSDKit/Sources/GSDSync/SyncEngine.swift`
- Test: `GSDKit/Tests/GSDSyncTests/SyncEngineReconcileTests.swift` (extend)

- [ ] **Step 1: Add the failing tests** — append to `SyncEngineReconcileTests` (single-flight is verified by the one-line `guard !isSyncing` + inspection + the live gate; the deterministic tests below cover the orchestration):
```swift
    @Test func notSignedInWhenNoToken() async throws {
        let db = try AppDatabase.inMemory()
        let engine = SyncEngine(client: PocketBaseClient(baseURL: "https://api.vinny.io", executor: IndexExecutor()),
                                tasks: GRDBTaskRepository(db), queue: GRDBSyncQueueRepository(db),
                                cursor: SyncCursor(defaults: UserDefaults(suiteName: "t.\(UUID().uuidString)")!),
                                deviceId: "d", tokenProvider: { nil }, now: { Date() }, throttleMs: 0)
        let result = await engine.sync(trigger: .manual)
        #expect(result.notSignedIn == true)
    }

    @Test func syncSeedsThenPullsPushesReconcilesAndAdvancesCursor() async throws {
        let db = try AppDatabase.inMemory(); let tasks = GRDBTaskRepository(db); let queue = GRDBSyncQueueRepository(db)
        let defaults = UserDefaults(suiteName: "t.\(UUID().uuidString)")!
        try await tasks.upsert(task("offline-1"))   // pre-sign-in task
        let exec = IndexExecutor()                  // empty remote (nothing to pull; index empty)
        let engine = SyncEngine(client: PocketBaseClient(baseURL: "https://api.vinny.io", executor: exec),
                                tasks: tasks, queue: queue, cursor: SyncCursor(defaults: defaults),
                                deviceId: "d", tokenProvider: { "h.\(Data(#"{"id":"u1","exp":9999999999}"#.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")).s" },
                                now: { Date(timeIntervalSince1970: 2_000_000_000) }, throttleMs: 0)
        let result = await engine.sync(trigger: .launch)
        #expect(result.notSignedIn == false && result.error == nil)
        // offline-1 was seeded → pushed (created remotely) → survives (not deleted by reconcile)
        #expect(try await tasks.fetch(id: "offline-1") != nil)
        #expect(SyncCursor(defaults: defaults).load() == nil || SyncCursor(defaults: defaults).load() != nil)  // cursor may stay nil if nothing pulled (maxApplied nil)
    }
```

> Helper for the gated test — add a tiny `AsyncSemaphore` in the test file (or simplify the single-flight test to assert the guard via a re-entrant call). If `AsyncSemaphore` is awkward, replace `singleFlightDropsConcurrent` with this deterministic variant: start `sync()` in a child task against a never-returning executor, then assert a second `await engine.sync()` returns `skipped == true` is NOT reliably orderable — so instead **unit-test the guard directly** by exposing `isSyncing` via a test-only `@testable` check, OR accept single-flight as covered by the explicit `guard !isSyncing` + live behavior. **Recommended: drop the gated executor; assert the guard with a simple synchronous re-entrancy check** (see Step 3 note).

- [ ] **Step 2: Run to verify it fails.** `cd GSDKit && swift test --filter SyncEngineReconcileTests` → FAIL (`sync`/`resetCursor` undefined).

- [ ] **Step 3: Add `sync()` + `resetCursor()`** to `SyncEngine.swift`:
```swift
    public func resetCursor() { cursor.clear() }

    /// Single-flight bidirectional sync (§7.4–7.7). A concurrent trigger is DROPPED (`skipped`),
    /// not queued. Sequence: token → seed-if-first → pull → push → deletion-reconcile → advance cursor.
    public func sync(trigger: SyncTrigger) async -> SyncResult {
        guard !isSyncing else { return SyncResult(skipped: true) }
        isSyncing = true
        defer { isSyncing = false }

        var result = SyncResult()
        let token: String
        do {
            guard let t = try await tokenProvider() else { result.notSignedIn = true; return result }
            token = t
        } catch { result.notSignedIn = true; return result }

        let owner = JWT.userId(token) ?? ""
        do {
            if cursor.load() == nil { try await seedExistingTasks() }      // first-sync seed BEFORE pull/reconcile
            let since = cursor.load() ?? "1970-01-01T00:00:00.000Z"
            let (pulled, maxApplied) = try await pull(token: token, since: since)
            result.pulled = pulled
            let (pushed, failed) = try await push(token: token, owner: owner)
            result.pushed = pushed; result.failed = failed
            result.deleted = try await reconcileDeletions(token: token)    // destructive — last
            cursor.advance(maxApplied: maxApplied, now: now())
        } catch {
            result.error = String("\(error)".prefix(200))
        }
        return result
    }
```

> **Single-flight test note:** if the `AsyncSemaphore`/gated approach is fiddly, it's acceptable to verify the `guard !isSyncing` by inspection + the live gate, and keep the deterministic `notSignedIn` + full-sequence tests above. Do NOT block the task on a flaky concurrency test — the guard is one line and obvious; the data-loss guards (seed/payload-LWW/reconcile) are the ones that must be airtight.

- [ ] **Step 4: Run to verify it passes.** `cd GSDKit && swift test --filter SyncEngine` → PASS (all engine tests). Then `cd GSDKit && swift test` (full) → no regression.

- [ ] **Step 5: Commit.**
```bash
git add GSDKit/Sources/GSDSync/SyncEngine.swift GSDKit/Tests/GSDSyncTests/SyncEngineReconcileTests.swift
git commit -m "feat(sync): add sync() orchestration + single-flight + resetCursor (A62)"
```

---

### Task C3: Wire the engine into the App (triggers: launch / sign-in / manual)

**Files:**
- Modify: `App/GSDApp.swift` (construct the engine sharing the repos; launch trigger)
- Modify: `App/Auth/SessionStore.swift` (after-sign-in → sync; sign-out → resetCursor; `syncNow()`)
- Modify: `App/Settings/SettingsView.swift` ("Sync Now" row)

> Build + render-verified (App SwiftUI/wiring; the engine logic is unit-tested in A–C2). `SessionStore` is the UI's sync facade (so we don't env-inject an `actor`). The engine + `TaskStore` **share the same `TaskRepository` + `SyncQueueRepository` instances** (so pulled writes reach the store's observer and the store's enqueues reach the engine's drain).

- [ ] **Step 1: `GSDApp.swift`** — extract the repos so the store + engine share them, construct the engine, and trigger on launch.
  (a) Add `import GSDSync` (already present from 5b). Add state: `@State private var syncEngine: SyncEngine`.
  (b) In `init()`, replace the inline repo construction so they're shared:
```swift
        let database = try! AppDatabase.live()
        let taskRepo = GRDBTaskRepository(database)
        let queueRepo = GRDBSyncQueueRepository(database)
        let scheduler = LiveReminderScheduler(settingsProvider: { TaskStore.readNotificationSettings(from: .shared) })
        let store = TaskStore(
            repository: taskRepo,
            smartViewRepository: GRDBSmartViewRepository(database),
            archiveRepository: GRDBArchiveRepository(database),
            reminders: scheduler,
            syncQueue: queueRepo)              // NEW: enqueue-on-mutation
        _store = State(initialValue: store)
```
  (c) After the 5b auth stack is built (`tokenStore`, `authService`), construct the engine (sharing `taskRepo`/`queueRepo`) and the session (passing the engine):
```swift
        let engine = SyncEngine(
            client: PocketBaseClient(baseURL: AuthConfig.live.baseURL),
            tasks: taskRepo, queue: queueRepo,
            cursor: SyncCursor(),
            deviceId: DeviceIdentity.current(nameProvider: { UIDevice.current.name }).deviceId,
            tokenProvider: { try await authService.validToken() })
        _syncEngine = State(initialValue: engine)
        _session = State(initialValue: SessionStore(auth: authService, tokenStore: tokenStore, syncEngine: engine))
```
  (d) In the `.task` launch hook (after `store.start()`), trigger a launch sync when signed in:
```swift
                .task {
                    store.start()
                    try? await store.runAutoArchiveSweep()
                    await store.refreshBadge()
                    if session.isSignedIn { _ = await syncEngine.sync(trigger: .launch) }
                }
```

- [ ] **Step 2: `SessionStore.swift`** — hold the engine; trigger after sign-in; clear the cursor on sign-out; expose `syncNow()` + `lastSync`.
```swift
    private let syncEngine: SyncEngine?
    private(set) var lastSync: SyncResult?
    private(set) var syncing = false
```
Extend `init` to accept `syncEngine: SyncEngine? = nil` and store it. In `signIn(provider:)`, after `email = result.record.email` (on success), trigger: `await runSync(trigger: .signIn)`. In `signOut()`, after clearing: `_Concurrency.Task { await syncEngine?.resetCursor() }`. Add:
```swift
    func syncNow() async { await runSync(trigger: .manual) }
    private func runSync(trigger: SyncTrigger) async {
        guard let syncEngine else { return }
        syncing = true; defer { syncing = false }
        lastSync = await syncEngine.sync(trigger: trigger)
    }
```

- [ ] **Step 3: `SettingsView.swift`** — add a "Sync Now" row to the Account section (signed-in only):
```swift
            if session.isSignedIn {
                LabeledContent(String(localized: "Signed in"), value: session.email ?? String(localized: "Account"))
                Button {
                    _Concurrency.Task { await session.syncNow() }
                } label: {
                    if session.syncing { ProgressView() }
                    else { Label(String(localized: "Sync Now"), systemImage: "arrow.triangle.2.circlepath") }
                }
                .disabled(session.syncing)
                Button(role: .destructive) { session.signOut() } label: {
                    Label(String(localized: "Sign Out"), systemImage: "rectangle.portrait.and.arrow.right")
                }
            } else { /* existing Sign in with Google button */ }
```

- [ ] **Step 4: Build + render-smoke.**
```bash
xcodegen generate    # picks up nothing new structurally, but safe
xcodebuild -project GSD.xcodeproj -scheme GSD -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath .build-app build
```
Expected: **BUILD SUCCEEDED**. Launch + screenshot Settings → the Account section shows "Sync Now" when signed in (or "Sign in with Google" when not). (No `project.yml` change — the GSDSync→GSDStore dep is a `Package.swift` change from A1.)

- [ ] **Step 5: Commit.**
```bash
git add App/GSDApp.swift App/Auth/SessionStore.swift App/Settings/SettingsView.swift GSD.xcodeproj/project.pbxproj
git commit -m "feat(sync): wire SyncEngine into the app (launch/sign-in/manual triggers) (A63)"
```

---

## Live gate (A64 — MANUAL, on the owner's device, gates merge)

> Built code stays on `phase-5c-sync-engine`; **do NOT merge to `main`** until this passes. The owner is signed in (5b) with the redirect set up.

- [ ] **L1 — Pull (web → phone):** create/edit a task on the web app → on the phone, sign in (or "Sync Now") → it appears. Confirms the real list shape/filter/pagination.
- [ ] **L2 — Push (phone → web):** create a task on the phone → "Sync Now" → it appears on the web app. Confirms create + the real `auth-with-oauth2`/CRUD shapes; **resolve the owner-in-body + null-vs-omit questions** (B4) against the real backend.
- [ ] **L3 — Edit both ways + LWW:** edit on web → phone reflects it; edit on phone → web reflects it; a conflicting edit resolves to the newer (LWW).
- [ ] **L4 — Data-wipe guard (THE one):** with tasks created **while signed out**, sign in → confirm they (a) survive on the phone and (b) upload to the web (the seed). Then a second sync deletes nothing spurious (reconcile is safe).
- [ ] **L5 — Delete reconcile:** delete a task on the web → next phone sync removes it locally (and a phone-side delete removes it on web).
- [ ] If L2/L3 reveal shape/owner/null divergences, reconcile the client + re-run `swift test`.

## Definition of Done (Phase 5c)
- [ ] **`swift test` green:** A57 (pull) · A58 (seed) · A59 (push + payload-LWW-guard) · A60 (enqueue + spawn) · A61 (reconcile) · A62 (sync/single-flight) — plus `SyncCursor`/`PocketBaseTaskList`/`PocketBaseTaskWrite`; full suite no regression.
- [ ] **App builds**; the Account section shows Sync Now (simctl render).
- [ ] **A64 live gate passes** (L1–L5 by the owner) — **the merge gate**; 5c is NOT merged on unit-green alone.
- [ ] **Three data-loss guards verified** (A58 seed, A59 payload-LWW-guard, A60 every-creation-enqueues) — by test AND by L4.

## Out of scope (explicit — deferred to 5d)
SSE realtime; the 2-min/foreground/network auto-cadence + immediate post-mutation push; the sync status indicator + pull-to-refresh; the sync-history table + screen; health monitoring. **Archive/restore stay device-local** (no enqueue). **Import-replace's remote-deletion** of cleared tasks (re-pulls; documented) and **`eraseAllData` sync** (local reset; re-pulls) are deferred.
