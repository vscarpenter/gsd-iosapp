# Phase 5d — Realtime, Cadence & Sync Observability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make sync feel live (SSE realtime + auto-cadence + debounced push) and legible (status chip, history screen, health), and close the two deferred destructive behaviors (import-replace remote-deletion + erase-all remote wipe).

**Architecture:** A new app-layer `@MainActor @Observable SyncCoordinator` owns *when* sync fires (2-min timer, `NWPathMonitor`, `scenePhase`, debounced post-mutation push, SSE lifecycle) and *what status shows*; the pure `SyncEngine` actor in `GSDSync` stays the tested core and gains `applyRealtime`/`pushNow`/`eraseAllRemote`/history-recording. SSE parsing is a new Foundation-only `PocketBaseRealtime` in `GSDSync`; sync history is a new GRDB v5 table + repo in `GSDStore`. This mirrors the existing `SessionStore`-wraps-`AuthService` split.

**Tech Stack:** Swift 6, swift-testing (`@Test`/`#expect`/`#require`), GRDB, `URLSession.bytes` (SSE), `Network.NWPathMonitor`, SwiftUI `@Observable`. Spec: `docs/specs/2026-06-02-phase-5d-realtime-status.md`.

---

## File Structure

**Group A — History store + engine read/write + health (`swift test`)**
- Create `GSDKit/Sources/GSDStore/SyncHistoryEntry.swift` — the `SyncHistoryEntry` domain struct + `SyncStatus`/`TriggeredBy` enums.
- Create `GSDKit/Sources/GSDStore/SyncHistoryRecord.swift` — GRDB record ↔ domain mapper.
- Create `GSDKit/Sources/GSDStore/SyncHistoryRepository.swift` — protocol + `GRDBSyncHistoryRepository` + `NoopSyncHistoryRepository`.
- Modify `GSDKit/Sources/GSDStore/Migrations.swift` — add `registerV5` (`syncHistory` table).
- Create `GSDKit/Sources/GSDSync/SyncHealth.swift` — pure health computation.
- Modify `GSDKit/Sources/GSDSync/SyncEngine.swift` — add `history` dep, write entries in `sync()`, add read methods.
- Tests: `GSDKit/Tests/GSDStoreTests/SyncHistoryRepositoryTests.swift`, add a v5 case to `MigrationTests.swift`, `GSDKit/Tests/GSDSyncTests/SyncHealthTests.swift`, `GSDKit/Tests/GSDSyncTests/SyncEngineHistoryTests.swift`.

**Group B — `pushNow` + cadence + debounce + coordinator + status UI (`swift test` + MANUAL)**
- Modify `GSDKit/Sources/GSDSync/SyncEngine.swift` — add `pushNow()` + new `SyncTrigger` cases.
- Modify `GSDKit/Sources/GSDStore/TaskStore.swift` — add a `mutationObserver` hook fired after each enqueue.
- Create `App/Sync/SyncCoordinator.swift` — the lifecycle/status owner.
- Create `App/Sync/SyncStatusChip.swift` — the toolbar chip.
- Create `App/Sync/SyncHistoryView.swift` — the history screen.
- Modify `App/GSDApp.swift` — construct + inject the coordinator; drive it from `.task`/`scenePhase`.
- Modify `App/Auth/SessionStore.swift` — drop `lastSync`/`syncing`/`runSync`; delegate to the coordinator.
- Modify `App/Settings/SettingsView.swift` — Account section reads the coordinator; add `Sync History ›`.
- Modify `App/Matrix/MatrixView.swift` + `App/ContentView.swift` (iPad) — host the chip + `.refreshable`.
- Tests: `GSDKit/Tests/GSDSyncTests/SyncEnginePushNowTests.swift`, extend `GSDKit/Tests/GSDStoreTests/TaskStoreEnqueueTests.swift`.

**Group C — Realtime SSE (`swift test` + MANUAL; after Probe P1)**
- Create `GSDKit/Sources/GSDSync/SSEParser.swift` — pure SSE line-protocol parser.
- Create `GSDKit/Sources/GSDSync/PocketBaseRealtime.swift` — the streaming subscription → `AsyncStream` of events.
- Create `GSDKit/Sources/GSDSync/RealtimeEvent.swift` — the decoded `{action, record}` envelope.
- Modify `GSDKit/Sources/GSDSync/SyncEngine.swift` — add `applyRealtime(_:)`.
- Modify `App/Sync/SyncCoordinator.swift` — start/stop/reconnect the stream; apply events.
- Tests: `GSDKit/Tests/GSDSyncTests/SSEParserTests.swift`, `GSDKit/Tests/GSDSyncTests/SyncEngineRealtimeTests.swift`, fixtures under `GSDKit/Tests/GSDSyncTests/Fixtures/`.

**Group D — Destructive ops + confirmations (`swift test` + MANUAL)**
- Modify `GSDKit/Sources/GSDSync/SyncEngine.swift` — add `isErasing` gate (pull-suppression) + `eraseAllRemote()`.
- Modify `GSDKit/Sources/GSDStore/TaskStore.swift` — `importTasks(replace)` enqueues deletes for cleared ids; expose an erase-all-with-deletes path.
- Modify `App/Settings/DataStorageView.swift` — "affects all your devices" confirmations + drive the new paths.
- Tests: `GSDKit/Tests/GSDSyncTests/SyncEngineEraseTests.swift`, extend `GSDKit/Tests/GSDStoreTests/TaskStoreDataTests.swift`.

---

## Conventions for every task

- **Test framework:** swift-testing. Files begin `import Testing` + `import Foundation` (+ `@testable import GSDSync` / `import GSDStore` / `import GSDModel` as needed). Tests are `@Test func name() async throws`, structs group them, `@MainActor struct` when touching `TaskStore`/coordinator.
- **Run tests:** `cd /Users/vinnycarpenter/Projects/gsd-iosapp/GSDKit && swift test` (whole suite, sub-second). For one: `swift test --filter <TestStructName>`.
- **In-memory DB:** `let db = try AppDatabase.inMemory()`.
- **Isolated defaults:** `UserDefaults(suiteName: "t.\(UUID().uuidString)")!`.
- **Commit cadence:** commit after each task's tests pass. Conventional-commit prefixes (`feat(sync):`, `feat(5d):`, `test(sync):`).
- **App-layer (`App/…`) has no unit tests** — verified by build + simctl smoke at group end (see the Build/Smoke task in each group).

---

## Group A — History store + engine read/write + health

### Task A1: `SyncHistoryEntry` domain type

**Files:**
- Create: `GSDKit/Sources/GSDStore/SyncHistoryEntry.swift`

- [ ] **Step 1: Write the type** (no test yet — a plain value type; A4 exercises it)

```swift
import Foundation

/// One recorded sync attempt (§7.7). Persisted in the `syncHistory` table; surfaced in the
/// Sync History screen. Written by `SyncEngine` at the end of each `sync()`/`pushNow()`.
public struct SyncHistoryEntry: Sendable, Identifiable, Equatable {
    public enum Status: String, Codable, Sendable { case success, error, conflict, partial }
    public enum TriggeredBy: String, Codable, Sendable { case user, auto }

    public var id: String
    public var timestamp: Int            // ms when the attempt finished
    public var status: Status
    public var pushedCount: Int
    public var pulledCount: Int
    public var conflictsResolved: Int
    public var failedCount: Int?
    public var errorMessage: String?
    public var duration: Int?            // ms
    public var deviceId: String
    public var triggeredBy: TriggeredBy

    public init(id: String, timestamp: Int, status: Status, pushedCount: Int = 0,
                pulledCount: Int = 0, conflictsResolved: Int = 0, failedCount: Int? = nil,
                errorMessage: String? = nil, duration: Int? = nil, deviceId: String,
                triggeredBy: TriggeredBy) {
        self.id = id; self.timestamp = timestamp; self.status = status
        self.pushedCount = pushedCount; self.pulledCount = pulledCount
        self.conflictsResolved = conflictsResolved; self.failedCount = failedCount
        self.errorMessage = errorMessage; self.duration = duration
        self.deviceId = deviceId; self.triggeredBy = triggeredBy
    }
}

/// Aggregate counts for the Sync History screen header.
public struct SyncHistoryStats: Equatable, Sendable {
    public var totalSyncs: Int
    public var successes: Int
    public var totalPushed: Int
    public var totalPulled: Int
    public init(totalSyncs: Int = 0, successes: Int = 0, totalPushed: Int = 0, totalPulled: Int = 0) {
        self.totalSyncs = totalSyncs; self.successes = successes
        self.totalPushed = totalPushed; self.totalPulled = totalPulled
    }
}
```

- [ ] **Step 2: Build** — `cd GSDKit && swift build` → succeeds.

- [ ] **Step 3: Commit**

```bash
git add GSDKit/Sources/GSDStore/SyncHistoryEntry.swift
git commit -m "feat(5d): add SyncHistoryEntry + SyncHistoryStats value types"
```

### Task A2: v5 migration — `syncHistory` table

**Files:**
- Modify: `GSDKit/Sources/GSDStore/Migrations.swift`
- Test: `GSDKit/Tests/GSDStoreTests/MigrationTests.swift`

- [ ] **Step 1: Write the failing test** (append to `MigrationTests.swift`, inside the existing test struct)

```swift
@Test func v5CreatesSyncHistoryTable() throws {
    let db = try AppDatabase.inMemory()
    try db.writer.read { d in
        #expect(try d.tableExists("syncHistory"))
        let columns = Set(try d.columns(in: "syncHistory").map(\.name))
        #expect(columns == ["id", "timestamp", "status", "pushedCount", "pulledCount",
                            "conflictsResolved", "failedCount", "errorMessage", "duration",
                            "deviceId", "triggeredBy"])
    }
}
```

- [ ] **Step 2: Run it — fails** (`syncHistory` doesn't exist)

Run: `cd GSDKit && swift test --filter MigrationTests`
Expected: FAIL (`tableExists("syncHistory")` is false).

- [ ] **Step 3: Add `registerV5`** — in `Migrations.swift`, add the call inside `migrator` after `registerV4(&migrator)`:

```swift
        registerV4(&migrator)
        registerV5(&migrator)
        return migrator
```

and add the function (mirror `registerV4`'s style):

```swift
    static func registerV5(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v5") { db in
            try db.create(table: "syncHistory") { t in
                t.primaryKey("id", .text)
                t.column("timestamp", .integer).notNull().indexed()
                t.column("status", .text).notNull()
                t.column("pushedCount", .integer).notNull().defaults(to: 0)
                t.column("pulledCount", .integer).notNull().defaults(to: 0)
                t.column("conflictsResolved", .integer).notNull().defaults(to: 0)
                t.column("failedCount", .integer)
                t.column("errorMessage", .text)
                t.column("duration", .integer)
                t.column("deviceId", .text).notNull()
                t.column("triggeredBy", .text).notNull()
            }
        }
    }
```

- [ ] **Step 4: Run it — passes**

Run: `cd GSDKit && swift test --filter MigrationTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add GSDKit/Sources/GSDStore/Migrations.swift GSDKit/Tests/GSDStoreTests/MigrationTests.swift
git commit -m "feat(5d): add v5 syncHistory migration"
```

### Task A3: `SyncHistoryRecord` (GRDB mapper)

**Files:**
- Create: `GSDKit/Sources/GSDStore/SyncHistoryRecord.swift`

> Mirror the conformances in `GSDKit/Sources/GSDStore/SyncQueueRecord.swift` exactly (open it to confirm: `Codable, FetchableRecord, PersistableRecord` + `static let databaseTableName`).

- [ ] **Step 1: Write the record** (test arrives in A4 with the repo)

```swift
import Foundation
import GRDB

/// GRDB row for `syncHistory` (v5). Mirrors `SyncQueueRecord`'s conformances.
struct SyncHistoryRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "syncHistory"

    var id: String
    var timestamp: Int
    var status: String
    var pushedCount: Int
    var pulledCount: Int
    var conflictsResolved: Int
    var failedCount: Int?
    var errorMessage: String?
    var duration: Int?
    var deviceId: String
    var triggeredBy: String

    init(_ e: SyncHistoryEntry) {
        id = e.id; timestamp = e.timestamp; status = e.status.rawValue
        pushedCount = e.pushedCount; pulledCount = e.pulledCount
        conflictsResolved = e.conflictsResolved; failedCount = e.failedCount
        errorMessage = e.errorMessage; duration = e.duration
        deviceId = e.deviceId; triggeredBy = e.triggeredBy.rawValue
    }

    func toDomain() -> SyncHistoryEntry {
        SyncHistoryEntry(
            id: id, timestamp: timestamp,
            status: SyncHistoryEntry.Status(rawValue: status) ?? .success,
            pushedCount: pushedCount, pulledCount: pulledCount,
            conflictsResolved: conflictsResolved, failedCount: failedCount,
            errorMessage: errorMessage, duration: duration, deviceId: deviceId,
            triggeredBy: SyncHistoryEntry.TriggeredBy(rawValue: triggeredBy) ?? .auto)
    }
}
```

- [ ] **Step 2: Build** — `cd GSDKit && swift build` → succeeds.

- [ ] **Step 3: Commit**

```bash
git add GSDKit/Sources/GSDStore/SyncHistoryRecord.swift
git commit -m "feat(5d): add SyncHistoryRecord GRDB mapper"
```

### Task A4: `SyncHistoryRepository` (+ Noop) + round-trip/stats tests

**Files:**
- Create: `GSDKit/Sources/GSDStore/SyncHistoryRepository.swift`
- Test: `GSDKit/Tests/GSDStoreTests/SyncHistoryRepositoryTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import GSDStore

struct SyncHistoryRepositoryTests {
    private func makeRepo() throws -> GRDBSyncHistoryRepository {
        GRDBSyncHistoryRepository(try AppDatabase.inMemory())
    }
    private func entry(_ id: String, ts: Int, status: SyncHistoryEntry.Status = .success,
                       pushed: Int = 0, pulled: Int = 0) -> SyncHistoryEntry {
        SyncHistoryEntry(id: id, timestamp: ts, status: status, pushedCount: pushed,
                         pulledCount: pulled, deviceId: "dev-A", triggeredBy: .auto)
    }

    @Test func insertAndRecentRoundTripsNewestFirst() async throws {
        let repo = try makeRepo()
        try await repo.insert(entry("a", ts: 100))
        try await repo.insert(entry("b", ts: 300))
        try await repo.insert(entry("c", ts: 200))
        let recent = try await repo.recent(limit: 50)
        #expect(recent.map(\.id) == ["b", "c", "a"])      // timestamp desc
        #expect(recent[0].deviceId == "dev-A")
    }

    @Test func recentRespectsLimit() async throws {
        let repo = try makeRepo()
        for i in 0..<5 { try await repo.insert(entry("e\(i)", ts: i)) }
        #expect(try await repo.recent(limit: 2).count == 2)
    }

    @Test func statsAggregate() async throws {
        let repo = try makeRepo()
        try await repo.insert(entry("a", ts: 1, status: .success, pushed: 2, pulled: 1))
        try await repo.insert(entry("b", ts: 2, status: .error, pushed: 0, pulled: 0))
        try await repo.insert(entry("c", ts: 3, status: .success, pushed: 3, pulled: 4))
        let s = try await repo.stats()
        #expect(s == SyncHistoryStats(totalSyncs: 3, successes: 2, totalPushed: 5, totalPulled: 5))
    }

    @Test func pruneKeepsNewest() async throws {
        let repo = try makeRepo()
        for i in 0..<6 { try await repo.insert(entry("e\(i)", ts: i)) }
        try await repo.prune(keeping: 3)
        let kept = try await repo.recent(limit: 50).map(\.id)
        #expect(kept == ["e5", "e4", "e3"])
    }
}
```

- [ ] **Step 2: Run — fails** (`GRDBSyncHistoryRepository` undefined)

Run: `cd GSDKit && swift test --filter SyncHistoryRepositoryTests`
Expected: FAIL (compile error / undefined symbol).

- [ ] **Step 3: Write the repository**

```swift
import Foundation
import GRDB

/// Async persistence for sync history (§7.7). Holds no business rules; the engine builds the
/// entries. `recent` is timestamp-desc; `prune` bounds the table. Mirrors the other GRDB repos.
public protocol SyncHistoryRepository: Sendable {
    func insert(_ entry: SyncHistoryEntry) async throws
    func recent(limit: Int) async throws -> [SyncHistoryEntry]
    func stats() async throws -> SyncHistoryStats
    func prune(keeping: Int) async throws
}

public final class GRDBSyncHistoryRepository: SyncHistoryRepository {
    private let dbWriter: any DatabaseWriter
    public init(_ database: AppDatabase) { self.dbWriter = database.writer }

    public func insert(_ entry: SyncHistoryEntry) async throws {
        let record = SyncHistoryRecord(entry)
        try await dbWriter.write { db in try record.save(db) }
    }

    public func recent(limit: Int) async throws -> [SyncHistoryEntry] {
        try await dbWriter.read { db in
            try SyncHistoryRecord.order(Column("timestamp").desc).limit(limit).fetchAll(db).map { $0.toDomain() }
        }
    }

    public func stats() async throws -> SyncHistoryStats {
        try await dbWriter.read { db in
            let all = try SyncHistoryRecord.fetchAll(db)
            return SyncHistoryStats(
                totalSyncs: all.count,
                successes: all.filter { $0.status == SyncHistoryEntry.Status.success.rawValue }.count,
                totalPushed: all.reduce(0) { $0 + $1.pushedCount },
                totalPulled: all.reduce(0) { $0 + $1.pulledCount })
        }
    }

    public func prune(keeping: Int) async throws {
        try await dbWriter.write { db in
            let survivors = try SyncHistoryRecord.order(Column("timestamp").desc).limit(keeping)
                .fetchAll(db).map(\.id)
            try SyncHistoryRecord.filter(!survivors.contains(Column("id"))).deleteAll(db)
        }
    }
}

/// Default no-op for `TaskStore`/`SyncEngine` when history isn't wired (tests / offline).
public struct NoopSyncHistoryRepository: SyncHistoryRepository {
    public init() {}
    public func insert(_ entry: SyncHistoryEntry) async throws {}
    public func recent(limit: Int) async throws -> [SyncHistoryEntry] { [] }
    public func stats() async throws -> SyncHistoryStats { SyncHistoryStats() }
    public func prune(keeping: Int) async throws {}
}
```

- [ ] **Step 4: Run — passes**

Run: `cd GSDKit && swift test --filter SyncHistoryRepositoryTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add GSDKit/Sources/GSDStore/SyncHistoryRepository.swift GSDKit/Tests/GSDStoreTests/SyncHistoryRepositoryTests.swift
git commit -m "feat(5d): add SyncHistoryRepository (+ Noop) with stats/prune"
```

### Task A5: `SyncQueueRepository.all()` (health needs failed items + oldest pending)

**Files:**
- Modify: `GSDKit/Sources/GSDStore/SyncQueueRepository.swift`
- Test: `GSDKit/Tests/GSDStoreTests/SyncQueueRepositoryTests.swift`

- [ ] **Step 1: Write the failing test** (append to the existing struct)

```swift
@Test func allReturnsPendingAndFailed() async throws {
    let repo = try makeRepo()
    try await repo.enqueue(SyncQueueItem(id: "p", taskId: "t1", operation: .update, timestamp: 1))
    var failed = SyncQueueItem(id: "f", taskId: "t2", operation: .update, timestamp: 2)
    failed.status = .failed
    try await repo.update(failed)
    let all = try await repo.all()
    #expect(Set(all.map(\.id)) == ["p", "f"])
}
```

- [ ] **Step 2: Run — fails** (`all()` undefined)

Run: `cd GSDKit && swift test --filter SyncQueueRepositoryTests`
Expected: FAIL (no member `all`).

- [ ] **Step 3: Add `all()` to the protocol + both conformers**

In the protocol:
```swift
    func all() async throws -> [SyncQueueItem]         // every item (pending + failed), timestamp asc
```
In `GRDBSyncQueueRepository`:
```swift
    public func all() async throws -> [SyncQueueItem] {
        try await dbWriter.read { db in
            try SyncQueueRecord.order(Column("timestamp")).fetchAll(db).map { try $0.toDomain() }
        }
    }
```
In `NoopSyncQueueRepository`:
```swift
    public func all() async throws -> [SyncQueueItem] { [] }
```

- [ ] **Step 4: Run — passes**

Run: `cd GSDKit && swift test --filter SyncQueueRepositoryTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add GSDKit/Sources/GSDStore/SyncQueueRepository.swift GSDKit/Tests/GSDStoreTests/SyncQueueRepositoryTests.swift
git commit -m "feat(5d): add SyncQueueRepository.all() for health checks"
```

### Task A6: `SyncHealth` pure evaluation

**Files:**
- Create: `GSDKit/Sources/GSDSync/SyncHealth.swift`
- Test: `GSDKit/Tests/GSDSyncTests/SyncHealthTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import GSDSync

struct SyncHealthTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func okWhenCleanAndOnline() {
        let h = SyncHealth.evaluate(oldestPendingMs: nil, failedCount: 0, tokenExpiry: now.addingTimeInterval(3600),
                                    online: true, now: now)
        #expect(h.level == .ok)
        #expect(h.message == nil)
    }

    @Test func warnsWhenOffline() {
        let h = SyncHealth.evaluate(oldestPendingMs: nil, failedCount: 0, tokenExpiry: nil, online: false, now: now)
        #expect(h.level == .warning)
        #expect(h.message != nil)
    }

    @Test func warnsOnFailedItems() {
        let h = SyncHealth.evaluate(oldestPendingMs: nil, failedCount: 3, tokenExpiry: now.addingTimeInterval(3600),
                                    online: true, now: now)
        #expect(h.level == .warning)
        #expect(h.message?.contains("3") == true)
    }

    @Test func warnsOnStalePending() {
        // oldest pending 2h ago (> 1h threshold)
        let twoHoursAgoMs = Int((now.addingTimeInterval(-7200)).timeIntervalSince1970 * 1000)
        let h = SyncHealth.evaluate(oldestPendingMs: twoHoursAgoMs, failedCount: 0,
                                    tokenExpiry: now.addingTimeInterval(3600), online: true, now: now)
        #expect(h.level == .warning)
    }

    @Test func okWhenPendingButFresh() {
        let fiveMinAgoMs = Int((now.addingTimeInterval(-300)).timeIntervalSince1970 * 1000)
        let h = SyncHealth.evaluate(oldestPendingMs: fiveMinAgoMs, failedCount: 0,
                                    tokenExpiry: now.addingTimeInterval(3600), online: true, now: now)
        #expect(h.level == .ok)
    }

    @Test func warnsWhenTokenExpired() {
        let h = SyncHealth.evaluate(oldestPendingMs: nil, failedCount: 0, tokenExpiry: now.addingTimeInterval(-10),
                                    online: true, now: now)
        #expect(h.level == .warning)
    }
}
```

- [ ] **Step 2: Run — fails** (`SyncHealth` undefined)

Run: `cd GSDKit && swift test --filter SyncHealthTests`
Expected: FAIL.

- [ ] **Step 3: Write `SyncHealth`** (priority: offline → failed → stale → token-expiry → ok)

```swift
import Foundation
import GSDStore   // (only for symmetry; uses primitives — no SyncQueueItem dependency here)

/// Non-alarming, actionable sync health (§7.7). Pure: the coordinator computes the primitives
/// (oldest-pending timestamp, failed count, token expiry, reachability) and this maps them to a
/// single user-facing level + message. Priority order: offline → failed → stale → token → ok.
public struct SyncHealth: Equatable, Sendable {
    public enum Level: Sendable, Equatable { case ok, warning }
    public var level: Level
    public var message: String?
    public init(level: Level, message: String?) { self.level = level; self.message = message }

    public static func evaluate(oldestPendingMs: Int?, failedCount: Int, tokenExpiry: Date?,
                                online: Bool, now: Date,
                                staleThresholdSeconds: TimeInterval = 3600) -> SyncHealth {
        if !online {
            return SyncHealth(level: .warning,
                              message: String(localized: "You're offline — changes will sync when you reconnect."))
        }
        if failedCount > 0 {
            return SyncHealth(level: .warning,
                              message: String(localized: "\(failedCount) changes failed to sync — tap Sync Now to retry."))
        }
        if let oldestPendingMs {
            let ageSeconds = now.timeIntervalSince1970 - Double(oldestPendingMs) / 1000
            if ageSeconds > staleThresholdSeconds {
                return SyncHealth(level: .warning,
                                  message: String(localized: "Some changes haven't synced in a while — tap Sync Now."))
            }
        }
        if let tokenExpiry, tokenExpiry <= now {
            return SyncHealth(level: .warning,
                              message: String(localized: "Your session expired — sign in again to keep syncing."))
        }
        return SyncHealth(level: .ok, message: nil)
    }
}
```

- [ ] **Step 4: Run — passes**

Run: `cd GSDKit && swift test --filter SyncHealthTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add GSDKit/Sources/GSDSync/SyncHealth.swift GSDKit/Tests/GSDSyncTests/SyncHealthTests.swift
git commit -m "feat(5d): add pure SyncHealth evaluation"
```

### Task A7: `SyncEngine` records history + read methods

**Files:**
- Modify: `GSDKit/Sources/GSDSync/SyncEngine.swift`
- Test: `GSDKit/Tests/GSDSyncTests/SyncEngineHistoryTests.swift`

> This task: (1) adds new `SyncTrigger` cases, (2) gives `pull` a conflict count, (3) injects a defaulted `history` repo, (4) writes one entry per `sync()`, (5) adds `recentHistory`/`historyStats` read passthroughs. The defaulted `history` param keeps `GSDApp`/existing tests compiling (real repo wired in Group B).

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import GSDSync
import GSDStore
import GSDModel

struct SyncEngineHistoryTests {
    final class EmptyExecutor: RequestExecuting, @unchecked Sendable {
        func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            (Data(#"{"page":1,"perPage":200,"totalItems":0,"totalPages":1,"items":[]}"#.utf8),
             HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }
    // A real JWT with id claim; reuse the project's existing test token if present, else this minimal one.
    // header {"alg":"HS256"} . payload {"id":"u1","exp":9999999999} . sig
    let token = "eyJhbGciOiJIUzI1NiJ9.eyJpZCI6InUxIiwiZXhwIjo5OTk5OTk5OTk5fQ.x"

    @Test func syncWritesOneSuccessEntry() async throws {
        let db = try AppDatabase.inMemory()
        let tasks = GRDBTaskRepository(db); let queue = GRDBSyncQueueRepository(db)
        let history = GRDBSyncHistoryRepository(db)
        let suite = UserDefaults(suiteName: "t.\(UUID().uuidString)")!
        let engine = SyncEngine(
            client: PocketBaseClient(baseURL: "https://api.vinny.io", executor: EmptyExecutor()),
            tasks: tasks, queue: queue, cursor: SyncCursor(defaults: suite), deviceId: "dev-A",
            tokenProvider: { self.token }, now: { Date(timeIntervalSince1970: 2_000_000_000) },
            throttleMs: 0, history: history)
        _ = await engine.sync(trigger: .manual)
        let recent = try await history.recent(limit: 10)
        #expect(recent.count == 1)
        #expect(recent[0].status == .success)
        #expect(recent[0].triggeredBy == .user)        // .manual → user
        #expect(recent[0].deviceId == "dev-A")
    }

    @Test func notSignedInWritesNoEntry() async throws {
        let db = try AppDatabase.inMemory()
        let history = GRDBSyncHistoryRepository(db)
        let suite = UserDefaults(suiteName: "t.\(UUID().uuidString)")!
        let engine = SyncEngine(
            client: PocketBaseClient(baseURL: "https://api.vinny.io", executor: EmptyExecutor()),
            tasks: GRDBTaskRepository(db), queue: GRDBSyncQueueRepository(db),
            cursor: SyncCursor(defaults: suite), deviceId: "dev-A",
            tokenProvider: { nil }, now: { Date(timeIntervalSince1970: 2_000_000_000) },
            throttleMs: 0, history: history)
        _ = await engine.sync(trigger: .launch)
        #expect(try await history.recent(limit: 10).isEmpty)   // no attempt → no record
    }
}
```

- [ ] **Step 2: Run — fails** (`history:` param + new behavior don't exist)

Run: `cd GSDKit && swift test --filter SyncEngineHistoryTests`
Expected: FAIL (compile error: extra argument `history`).

- [ ] **Step 3: Edit `SyncEngine.swift`**

(a) Extend the trigger enum:
```swift
public enum SyncTrigger: Sendable { case launch, signIn, manual, foreground, periodic, networkRegained, mutation }
```

(b) Add the stored dep + init param (defaulted to Noop so existing call sites compile). In the property block:
```swift
    private let history: any SyncHistoryRepository
```
In `init`, add the parameter at the end (after `throttleMs`):
```swift
                throttleMs: Int = 100,
                history: any SyncHistoryRepository = NoopSyncHistoryRepository()) {
```
and assign it in the body:
```swift
        self.throttleMs = throttleMs; self.history = history
```

(c) Give `pull` a conflict count — change its signature + body:
```swift
    func pull(token: String, since: String) async throws -> (applied: Int, conflicts: Int, maxApplied: Date?) {
        let records = try await client.listTasks(updatedSince: since, token: token)
        var applied = 0
        var conflicts = 0
        var maxApplied: Date?
        for record in records {
            guard let remoteUpdated = WireDate.parse(record.clientUpdatedAt) else { continue }
            maxApplied = max(maxApplied ?? .distantPast, remoteUpdated)
            let local = try await tasks.fetch(id: record.taskId)
            let decision = LWW.resolve(localUpdatedAt: local?.updatedAt, remoteClientUpdatedAt: remoteUpdated)
            guard local == nil || decision == .takeRemote else { continue }
            if local != nil && decision == .takeRemote { conflicts += 1 }   // a real conflict resolved in remote's favor
            try await tasks.upsert(TaskWireMapper.toDomain(record, mergingInto: local))
            applied += 1
        }
        return (applied, conflicts, maxApplied)
    }
```

(d) In `sync(trigger:)`, capture the conflict count, compute timing, and record. Replace the `do { … } catch { … }` block's body so it reads:
```swift
        let start = now()
        do {
            if cursor.load() == nil { try await seedExistingTasks() }
            let since = cursor.load() ?? "1970-01-01T00:00:00.000Z"
            let (pulled, conflicts, maxApplied) = try await pull(token: token, since: since)
            result.pulled = pulled
            let (pushed, failed) = try await push(token: token, owner: owner)
            result.pushed = pushed; result.failed = failed
            result.deleted = try await reconcileDeletions(token: token)
            cursor.advance(maxApplied: maxApplied, now: now())
            await record(trigger: trigger, result: result, conflicts: conflicts, start: start)
        } catch {
            result.error = String("\(error)".prefix(200))
            await record(trigger: trigger, result: result, conflicts: 0, start: start)
        }
        return result
```

(e) Add the private recorder + a trigger→triggeredBy mapping + the read passthroughs (place near the bottom of the actor):
```swift
    /// Map a trigger to history's user/auto axis. Only explicit Sync-Now / pull-to-refresh is "user".
    private func triggeredBy(_ trigger: SyncTrigger) -> SyncHistoryEntry.TriggeredBy {
        trigger == .manual ? .user : .auto
    }

    /// Build + persist one history entry for a completed attempt. Status precedence: error > partial
    /// (some pushes failed) > conflict (LWW resolved a remote-wins overwrite) > success.
    private func record(trigger: SyncTrigger, result: SyncResult, conflicts: Int, start: Date) async {
        let end = now()
        let status: SyncHistoryEntry.Status =
            result.error != nil ? .error :
            result.failed > 0   ? .partial :
            conflicts > 0       ? .conflict : .success
        let entry = SyncHistoryEntry(
            id: UUID().uuidString,
            timestamp: Int(end.timeIntervalSince1970 * 1000),
            status: status, pushedCount: result.pushed, pulledCount: result.pulled,
            conflictsResolved: conflicts, failedCount: result.failed > 0 ? result.failed : nil,
            errorMessage: result.error, duration: Int(end.timeIntervalSince(start) * 1000),
            deviceId: deviceId, triggeredBy: triggeredBy(trigger))
        try? await history.insert(entry)
        try? await history.prune(keeping: 500)
    }

    /// Read passthroughs for the Sync History screen (keeps GSDSync the single sync API surface).
    public func recentHistory(limit: Int = 50) async -> [SyncHistoryEntry] {
        (try? await history.recent(limit: limit)) ?? []
    }
    public func historyStats() async -> SyncHistoryStats {
        (try? await history.stats()) ?? SyncHistoryStats()
    }
```

> NOTE: `pull` is also called nowhere else, but its return tuple changed; the only caller is `sync()`. If any test calls `pull` directly and breaks on the new tuple, update it to destructure 3 values.

- [ ] **Step 4: Run the whole suite** (the `pull` signature change can ripple)

Run: `cd GSDKit && swift test`
Expected: PASS (all prior tests + the 2 new ones). If a pull-tuple call site fails to compile, fix it to `(applied, conflicts, maxApplied)`.

- [ ] **Step 5: Commit**

```bash
git add GSDKit/Sources/GSDSync/SyncEngine.swift GSDKit/Tests/GSDSyncTests/SyncEngineHistoryTests.swift
git commit -m "feat(5d): SyncEngine records sync history + exposes read passthroughs"
```

### Task A8: Group A checkpoint

- [ ] **Step 1: Full suite green**

Run: `cd GSDKit && swift test`
Expected: PASS, count = prior total + new (history repo 4, migration 1, queue.all 1, health 6, engine history 2).

- [ ] **Step 2: No commit needed** (all committed). Group A is pure logic — no app build required yet.

---

## Group B — `pushNow` + cadence + debounce + coordinator + status UI

### Task B1: `SyncEngine.pushNow()` (push-only fast path)

**Files:**
- Modify: `GSDKit/Sources/GSDSync/SyncEngine.swift`
- Test: `GSDKit/Tests/GSDSyncTests/SyncEnginePushNowTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import GSDSync
import GSDStore
import GSDModel

struct SyncEnginePushNowTests {
    // Remote index returns one record "r1" (absent locally); writes are recorded.
    final class IndexExecutor: RequestExecuting, @unchecked Sendable {
        private(set) var writes: [(method: String, path: String)] = []
        func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let m = request.httpMethod ?? "GET"
            if m == "GET" {
                let json = #"{"page":1,"perPage":200,"totalItems":1,"totalPages":1,"items":[{"id":"rec1","task_id":"r1","client_updated_at":"2001-01-01T00:00:00.000Z"}]}"#
                return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            writes.append((m, request.url!.path))
            let body = #"{"id":"recX","task_id":"a","title":"t","urgent":false,"important":false}"#
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }
    let token = "eyJhbGciOiJIUzI1NiJ9.eyJpZCI6InUxIiwiZXhwIjo5OTk5OTk5OTk5fQ.x"

    private func engine(_ db: AppDatabase, _ exec: RequestExecuting) -> SyncEngine {
        SyncEngine(client: PocketBaseClient(baseURL: "https://api.vinny.io", executor: exec),
                   tasks: GRDBTaskRepository(db), queue: GRDBSyncQueueRepository(db),
                   cursor: SyncCursor(defaults: UserDefaults(suiteName: "t.\(UUID().uuidString)")!),
                   deviceId: "dev-A", tokenProvider: { self.token },
                   now: { Date(timeIntervalSince1970: 2_000_000_000) }, throttleMs: 0,
                   history: GRDBSyncHistoryRepository(db))
    }

    @Test func pushNowDrainsQueueWithoutPullingOrReconciling() async throws {
        let db = try AppDatabase.inMemory()
        let tasks = GRDBTaskRepository(db); let queue = GRDBSyncQueueRepository(db)
        // a local task absent remotely — reconcile WOULD delete it; pushNow must NOT.
        let local = Task(id: "keepme", title: "local only", urgent: false, important: false,
                         createdAt: Date(timeIntervalSince1970: 5_000_000), updatedAt: Date(timeIntervalSince1970: 5_000_000))
        try await tasks.upsert(local)
        // a pending create to push
        let toPush = Task(id: "a", title: "push me", urgent: false, important: false,
                          createdAt: Date(timeIntervalSince1970: 5_000_000), updatedAt: Date(timeIntervalSince1970: 5_000_000))
        try await queue.enqueue(SyncQueueItem(id: "q1", taskId: "a", operation: .create, timestamp: 1, payload: toPush))
        let exec = IndexExecutor()
        let eng = SyncEngine(client: PocketBaseClient(baseURL: "https://api.vinny.io", executor: exec),
                             tasks: tasks, queue: queue,
                             cursor: SyncCursor(defaults: UserDefaults(suiteName: "t.\(UUID().uuidString)")!),
                             deviceId: "dev-A", tokenProvider: { self.token },
                             now: { Date(timeIntervalSince1970: 2_000_000_000) }, throttleMs: 0,
                             history: GRDBSyncHistoryRepository(db))
        let result = await eng.pushNow()
        #expect(result.pushed == 1)
        #expect(exec.writes.contains { $0.method == "POST" })
        // NOT pulled: remote "r1" never became a local task
        #expect(try await tasks.fetch(id: "r1") == nil)
        // NOT reconciled: the local-only task survives
        #expect(try await tasks.fetch(id: "keepme") != nil)
    }

    @Test func pushNowRecordsHistory() async throws {
        let db = try AppDatabase.inMemory()
        let history = GRDBSyncHistoryRepository(db)
        let eng = SyncEngine(client: PocketBaseClient(baseURL: "https://api.vinny.io", executor: IndexExecutor()),
                             tasks: GRDBTaskRepository(db), queue: GRDBSyncQueueRepository(db),
                             cursor: SyncCursor(defaults: UserDefaults(suiteName: "t.\(UUID().uuidString)")!),
                             deviceId: "dev-A", tokenProvider: { self.token },
                             now: { Date(timeIntervalSince1970: 2_000_000_000) }, throttleMs: 0, history: history)
        _ = await eng.pushNow()
        #expect(try await history.recent(limit: 5).count == 1)
    }
}
```

- [ ] **Step 2: Run — fails** (`pushNow` undefined)

Run: `cd GSDKit && swift test --filter SyncEnginePushNowTests`
Expected: FAIL.

- [ ] **Step 3: Add `pushNow()`** to `SyncEngine` (place after `sync(trigger:)`)

```swift
    /// Push-only fast path for the debounced post-mutation trigger (§7.6): drains the queue with the
    /// same LWW-guard / throttle / 429-abort / across-sync-retry as `sync()`, but does NOT pull or
    /// reconcile. Shares the single-flight flag (a concurrent full `sync()` drops it). Records history.
    public func pushNow(trigger: SyncTrigger = .mutation) async -> SyncResult {
        guard !isSyncing else { return SyncResult(skipped: true) }
        isSyncing = true
        defer { isSyncing = false }

        var result = SyncResult()
        let token: String
        do {
            guard let t = try await tokenProvider() else { result.notSignedIn = true; return result }
            token = t
        } catch { result.notSignedIn = true; return result }
        guard let owner = JWT.userId(token) else {
            result.error = "Could not derive owner from auth token"; return result
        }
        let start = now()
        do {
            let (pushed, failed) = try await push(token: token, owner: owner)
            result.pushed = pushed; result.failed = failed
            await record(trigger: trigger, result: result, conflicts: 0, start: start)
        } catch {
            result.error = String("\(error)".prefix(200))
            await record(trigger: trigger, result: result, conflicts: 0, start: start)
        }
        return result
    }
```

- [ ] **Step 4: Run — passes**

Run: `cd GSDKit && swift test --filter SyncEnginePushNowTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add GSDKit/Sources/GSDSync/SyncEngine.swift GSDKit/Tests/GSDSyncTests/SyncEnginePushNowTests.swift
git commit -m "feat(5d): add SyncEngine.pushNow() push-only fast path"
```

### Task B2: `SyncEngine.health(online:)` + `pendingCount()`

**Files:**
- Modify: `GSDKit/Sources/GSDSync/SyncEngine.swift`
- Test: `GSDKit/Tests/GSDSyncTests/SyncEngineHealthTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import GSDSync
import GSDStore
import GSDModel

struct SyncEngineHealthTests {
    final class EmptyExecutor: RequestExecuting, @unchecked Sendable {
        func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            (Data(#"{"page":1,"perPage":200,"totalItems":0,"totalPages":1,"items":[]}"#.utf8),
             HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }
    let token = "eyJhbGciOiJIUzI1NiJ9.eyJpZCI6InUxIiwiZXhwIjo5OTk5OTk5OTk5fQ.x"

    private func engine(_ db: AppDatabase) -> SyncEngine {
        SyncEngine(client: PocketBaseClient(baseURL: "https://api.vinny.io", executor: EmptyExecutor()),
                   tasks: GRDBTaskRepository(db), queue: GRDBSyncQueueRepository(db),
                   cursor: SyncCursor(defaults: UserDefaults(suiteName: "t.\(UUID().uuidString)")!),
                   deviceId: "dev-A", tokenProvider: { self.token },
                   now: { Date(timeIntervalSince1970: 1_000_000) }, throttleMs: 0,
                   history: GRDBSyncHistoryRepository(db))
    }

    @Test func healthOkWhenCleanOnline() async throws {
        let h = await engine(try AppDatabase.inMemory()).health(online: true)
        #expect(h.level == .ok)
    }

    @Test func healthWarnsOffline() async throws {
        let h = await engine(try AppDatabase.inMemory()).health(online: false)
        #expect(h.level == .warning)
    }

    @Test func pendingCountReflectsQueue() async throws {
        let db = try AppDatabase.inMemory(); let queue = GRDBSyncQueueRepository(db)
        try await queue.enqueue(SyncQueueItem(id: "q1", taskId: "a", operation: .update, timestamp: 1))
        try await queue.enqueue(SyncQueueItem(id: "q2", taskId: "b", operation: .update, timestamp: 2))
        let eng = SyncEngine(client: PocketBaseClient(baseURL: "https://api.vinny.io", executor: EmptyExecutor()),
                             tasks: GRDBTaskRepository(db), queue: queue,
                             cursor: SyncCursor(defaults: UserDefaults(suiteName: "t.\(UUID().uuidString)")!),
                             deviceId: "dev-A", tokenProvider: { self.token },
                             now: { Date(timeIntervalSince1970: 1_000_000) }, throttleMs: 0,
                             history: GRDBSyncHistoryRepository(db))
        #expect(await eng.pendingCount() == 2)
    }
}
```

- [ ] **Step 2: Run — fails**

Run: `cd GSDKit && swift test --filter SyncEngineHealthTests`
Expected: FAIL (`health`/`pendingCount` undefined).

- [ ] **Step 3: Add the methods** to `SyncEngine` (place near the read passthroughs)

```swift
    /// Pending push count for the status chip.
    public func pendingCount() async -> Int { (try? await queue.pending().count) ?? 0 }

    /// Compute current health (§7.7) from the queue + token + reachability (the App supplies `online`).
    public func health(online: Bool) async -> SyncHealth {
        let items = (try? await queue.all()) ?? []
        let oldestPendingMs = items.filter { $0.status == .pending }.map(\.timestamp).min()
        let failedCount = items.filter { $0.status == .failed }.count
        let token = try? await tokenProvider()
        let expiry = token.flatMap { $0 }.flatMap { JWT.expiry($0) }
        return SyncHealth.evaluate(oldestPendingMs: oldestPendingMs, failedCount: failedCount,
                                   tokenExpiry: expiry, online: online, now: now())
    }
```

- [ ] **Step 4: Run — passes**

Run: `cd GSDKit && swift test --filter SyncEngineHealthTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add GSDKit/Sources/GSDSync/SyncEngine.swift GSDKit/Tests/GSDSyncTests/SyncEngineHealthTests.swift
git commit -m "feat(5d): add SyncEngine.health(online:) + pendingCount()"
```

### Task B3: `TaskStore` mutation hook

**Files:**
- Modify: `GSDKit/Sources/GSDStore/TaskStore.swift`
- Test: `GSDKit/Tests/GSDStoreTests/TaskStoreEnqueueTests.swift`

- [ ] **Step 1: Write the failing test** (append to `TaskStoreEnqueueTests`)

```swift
@Test func mutationFiresOnMutationHook() async throws {
    let q = RecordingQueue(); let store = try makeStore(q)
    final class Counter: @unchecked Sendable { var n = 0 }
    let counter = Counter()
    store.onMutation = { counter.n += 1 }
    try await store.add(ParsedCapture(title: "Quick", urgent: true, important: false, tags: [], descriptionAdditions: []))
    #expect(counter.n == 1)
}
```

> If `makeStore`/`RecordingQueue` differ in this file, reuse whatever the existing tests use — only the `onMutation` assertion is new.

- [ ] **Step 2: Run — fails** (`onMutation` undefined)

Run: `cd GSDKit && swift test --filter TaskStoreEnqueueTests`
Expected: FAIL.

- [ ] **Step 3: Add the hook** to `TaskStore`

Add the property near the other private deps (after `private var pinnedIDs`):
```swift
    /// Fired after every enqueue so the App can schedule a debounced push (5d). Not observed.
    @ObservationIgnored public var onMutation: (() -> Void)?
```
In the private `enqueue(...)` helper, after `try? await syncQueue.enqueue(item)`:
```swift
        try? await syncQueue.enqueue(item)
        onMutation?()
```

- [ ] **Step 4: Run — passes**

Run: `cd GSDKit && swift test --filter TaskStoreEnqueueTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add GSDKit/Sources/GSDStore/TaskStore.swift GSDKit/Tests/GSDStoreTests/TaskStoreEnqueueTests.swift
git commit -m "feat(5d): add TaskStore.onMutation hook for debounced push"
```

### Task B4: `SyncCoordinator` (app lifecycle + status owner)

**Files:**
- Create: `App/Sync/SyncCoordinator.swift`

> App-layer glue — no unit tests; verified by build + simctl (B11). `XcodeGen` globs `App/`, so the new `App/Sync/` folder is picked up on `xcodegen generate` (B11). The SSE pieces are stubbed here and filled in Group C (marked `// Group C`).

- [ ] **Step 1: Create the file**

```swift
import Foundation
import Observation
import Network
import GSDSync
import GSDStore

/// Owns *when* sync fires and *what status shows* (§7.6/§7.7). The pure `SyncEngine` stays the
/// tested core; this is the app-lifecycle wrapper (the `SessionStore`-wraps-`AuthService` precedent).
/// Owns the 2-min cadence, reachability, scenePhase reactions, the debounced post-mutation push, and
/// (Group C) the SSE subscription lifecycle. `@MainActor @Observable` so the chip + Settings observe it.
@MainActor
@Observable
final class SyncCoordinator {
    enum Phase: Equatable { case idle, syncing, error }

    private(set) var phase: Phase = .idle
    private(set) var pendingCount = 0
    private(set) var lastSync: SyncResult?
    private(set) var health = SyncHealth(level: .ok, message: nil)

    private let engine: SyncEngine
    private let signedIn: @MainActor () -> Bool

    @ObservationIgnored private var cadenceTask: _Concurrency.Task<Void, Never>?
    @ObservationIgnored private var debounceTask: _Concurrency.Task<Void, Never>?
    @ObservationIgnored private var monitor: NWPathMonitor?
    @ObservationIgnored private var online = true
    @ObservationIgnored private var active = false

    init(engine: SyncEngine, signedIn: @escaping @MainActor () -> Bool) {
        self.engine = engine
        self.signedIn = signedIn
    }

    // MARK: Lifecycle

    /// Launch / after-sign-in: begin cadence + reachability and run an initial sync. (SSE start: Group C.)
    func start(trigger: SyncTrigger = .launch) {
        guard signedIn() else { return }
        active = true
        startReachability()
        startCadence()
        _Concurrency.Task { await self.runSync(trigger: trigger) }
    }

    /// Sign-out / teardown: stop everything (local data is NOT wiped — the engine keeps the cursor reset
    /// to its own resetCursor on sign-out, called by SessionStore).
    func stop() {
        active = false
        cadenceTask?.cancel(); cadenceTask = nil
        debounceTask?.cancel(); debounceTask = nil
        monitor?.cancel(); monitor = nil
        phase = .idle; pendingCount = 0
    }

    /// Sign-out: tear down AND reset the engine's pull cursor (re-seed + full-pull next sign-in;
    /// local tasks are NOT wiped). Keeps the engine out of `SessionStore`.
    func signedOut() {
        stop()
        _Concurrency.Task { await engine.resetCursor() }
    }

    func enteredForeground() {
        guard signedIn() else { return }
        active = true
        startReachability()
        startCadence()
        _Concurrency.Task { await self.runSync(trigger: .foreground) }
    }

    func enteredBackground() {
        active = false
        cadenceTask?.cancel(); cadenceTask = nil
        monitor?.cancel(); monitor = nil
    }

    // MARK: Triggers

    /// Manual "Sync Now" + pull-to-refresh.
    func syncNow() async { await runSync(trigger: .manual) }

    /// Debounced post-mutation push — called from `TaskStore.onMutation`. Coalesces rapid edits.
    func scheduleDebouncedPush() {
        guard signedIn() else { return }
        debounceTask?.cancel()
        debounceTask = _Concurrency.Task { [weak self] in
            try? await _Concurrency.Task.sleep(for: .milliseconds(1500))
            guard let self, !_Concurrency.Task.isCancelled else { return }
            await self.runPush()
        }
    }

    // MARK: Internals

    private func startCadence() {
        cadenceTask?.cancel()
        cadenceTask = _Concurrency.Task { [weak self] in
            while !_Concurrency.Task.isCancelled {
                try? await _Concurrency.Task.sleep(for: .seconds(120))
                guard let self, !_Concurrency.Task.isCancelled, self.active else { return }
                await self.runSync(trigger: .periodic)
            }
        }
    }

    private func startReachability() {
        guard monitor == nil else { return }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            let nowOnline = path.status == .satisfied
            _Concurrency.Task { @MainActor in
                guard let self else { return }
                let regained = nowOnline && !self.online
                self.online = nowOnline
                await self.refreshHealth()
                if regained, self.signedIn(), self.active {
                    await self.runSync(trigger: .networkRegained)
                }
            }
        }
        m.start(queue: DispatchQueue(label: "dev.vinny.gsd.reachability"))
        monitor = m
    }

    private func runSync(trigger: SyncTrigger) async {
        phase = .syncing
        let result = await engine.sync(trigger: trigger)
        apply(result)
    }

    private func runPush() async {
        phase = .syncing
        let result = await engine.pushNow()
        apply(result)
    }

    private func apply(_ result: SyncResult) {
        if !result.skipped { lastSync = result }
        phase = result.error != nil ? .error : .idle
        _Concurrency.Task { await self.refreshStatus() }
    }

    private func refreshStatus() async {
        pendingCount = await engine.pendingCount()
        await refreshHealth()
    }

    private func refreshHealth() async {
        health = await engine.health(online: online)
    }
}
```

- [ ] **Step 2: Build** (deferred to B11's `xcodegen` + build — this file alone won't compile standalone). Mark done; no commit yet (commit with B7 wiring).

### Task B5: `SyncStatusChip` (toolbar indicator)

**Files:**
- Create: `App/Sync/SyncStatusChip.swift`

- [ ] **Step 1: Create the file**

```swift
import SwiftUI
import GSDSync

/// Quiet toolbar status indicator (§7.7): hidden when idle/healthy; a spinner while syncing;
/// "↻N" when items are pending; an amber warning glyph on error/health-warning. Tapping invokes
/// `onTap` (the host routes to Settings → Account). Respects Reduce Motion (static glyph, no spin).
struct SyncStatusChip: View {
    let phase: SyncCoordinator.Phase
    let pendingCount: Int
    let health: SyncHealth
    let onTap: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Idle + healthy + nothing pending → render nothing (quiet until it matters).
    private var isQuiet: Bool {
        phase == .idle && pendingCount == 0 && health.level == .ok
    }

    var body: some View {
        if !isQuiet {
            Button(action: onTap) {
                label
            }
            .accessibilityLabel(accessibilityText)
        }
    }

    @ViewBuilder private var label: some View {
        switch phase {
        case .syncing:
            if reduceMotion {
                Image(systemName: "arrow.triangle.2.circlepath")
            } else {
                ProgressView().controlSize(.small)
            }
        case .error:
            Image(systemName: "exclamationmark.icloud").foregroundStyle(.orange)
        case .idle:
            if health.level == .warning {
                Image(systemName: "exclamationmark.icloud").foregroundStyle(.orange)
            } else if pendingCount > 0 {
                Label("\(pendingCount)", systemImage: "arrow.triangle.2.circlepath")
                    .labelStyle(.titleAndIcon).font(.footnote)
            }
        }
    }

    private var accessibilityText: String {
        switch phase {
        case .syncing: return String(localized: "Syncing")
        case .error:   return String(localized: "Sync error")
        case .idle:
            if health.level == .warning { return health.message ?? String(localized: "Sync warning") }
            return String(localized: "\(pendingCount) changes pending")
        }
    }
}
```

- [ ] **Step 2: Build** — deferred to B11. No commit yet.

### Task B6: `SyncHistoryView` (history screen)

**Files:**
- Create: `App/Sync/SyncHistoryView.swift`

- [ ] **Step 1: Create the file**

```swift
import SwiftUI
import GSDSync
import GSDStore

/// Sync History screen (§7.7): recent attempts + summary stats. Pushed from Settings → Account.
/// Reads through the engine (the single sync API surface).
struct SyncHistoryView: View {
    let engine: SyncEngine

    @State private var entries: [SyncHistoryEntry] = []
    @State private var stats = SyncHistoryStats()

    var body: some View {
        List {
            Section {
                LabeledContent(String(localized: "Total syncs"), value: "\(stats.totalSyncs)")
                LabeledContent(String(localized: "Successful"), value: "\(stats.successes)")
                LabeledContent(String(localized: "Pushed"), value: "\(stats.totalPushed)")
                LabeledContent(String(localized: "Pulled"), value: "\(stats.totalPulled)")
            }
            Section(String(localized: "Recent")) {
                if entries.isEmpty {
                    Text(String(localized: "No sync history yet.")).foregroundStyle(.secondary)
                }
                ForEach(entries) { entry in row(entry) }
            }
        }
        .navigationTitle(String(localized: "Sync History"))
        .task { await load() }
        .refreshable { await load() }
    }

    @ViewBuilder private func row(_ e: SyncHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: icon(e.status)).foregroundStyle(color(e.status))
                Text(title(e.status)).font(.subheadline.weight(.medium))
                Spacer()
                Text(date(e.timestamp)).font(.caption).foregroundStyle(.secondary)
            }
            Text(detail(e)).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func detail(_ e: SyncHistoryEntry) -> String {
        var parts = ["\(e.triggeredBy == .user ? String(localized: "Manual") : String(localized: "Auto"))",
                     "↑\(e.pushedCount)", "↓\(e.pulledCount)"]
        if e.conflictsResolved > 0 { parts.append("⚖\(e.conflictsResolved)") }
        if let f = e.failedCount, f > 0 { parts.append("⚠\(f)") }
        if let d = e.duration { parts.append("\(d) ms") }
        if let m = e.errorMessage { parts.append(m) }
        return parts.joined(separator: " · ")
    }

    private func icon(_ s: SyncHistoryEntry.Status) -> String {
        switch s {
        case .success:  "checkmark.circle.fill"
        case .conflict: "arrow.triangle.2.circlepath"
        case .partial:  "exclamationmark.triangle.fill"
        case .error:    "xmark.circle.fill"
        }
    }
    private func color(_ s: SyncHistoryEntry.Status) -> Color {
        switch s {
        case .success:  .green
        case .conflict: .blue
        case .partial:  .orange
        case .error:    .red
        }
    }
    private func title(_ s: SyncHistoryEntry.Status) -> String {
        switch s {
        case .success:  String(localized: "Success")
        case .conflict: String(localized: "Resolved conflicts")
        case .partial:  String(localized: "Partial")
        case .error:    String(localized: "Error")
        }
    }
    private func date(_ ms: Int) -> String {
        let d = Date(timeIntervalSince1970: Double(ms) / 1000)
        return d.formatted(date: .abbreviated, time: .shortened)
    }

    private func load() async {
        entries = await engine.recentHistory(limit: 50)
        stats = await engine.historyStats()
    }
}
```

- [ ] **Step 2: Build** — deferred to B11. No commit yet.

### Task B7: Wire the coordinator into `GSDApp` + pass the real history repo to the engine

**Files:**
- Modify: `App/GSDApp.swift`

- [ ] **Step 1: Add the history repo + coordinator + onMutation wiring** in `init()`.

(a) After `let queueRepo = GRDBSyncQueueRepository(database)` add:
```swift
        let historyRepo = GRDBSyncHistoryRepository(database)
```

(b) In the `SyncEngine(...)` construction, add the `history:` argument:
```swift
        let syncEngine = SyncEngine(
            client: PocketBaseClient(baseURL: AuthConfig.live.baseURL),
            tasks: taskRepo, queue: queueRepo,
            cursor: SyncCursor(),
            deviceId: DeviceIdentity.current(nameProvider: { deviceName }).deviceId,
            tokenProvider: { try await authService.validToken() },
            history: historyRepo)
        _syncEngine = State(initialValue: syncEngine)
```

(c) Replace the `_session = …` line with the coordinator construction + session + onMutation hook:
```swift
        let coordinator = SyncCoordinator(engine: syncEngine, signedIn: { tokenStore.load() != nil })
        _coordinator = State(initialValue: coordinator)
        store.onMutation = { coordinator.scheduleDebouncedPush() }
        _session = State(initialValue: SessionStore(auth: authService, tokenStore: tokenStore, coordinator: coordinator))
```

(d) Add the `@State` declaration near the others at the top of the struct:
```swift
    @State private var coordinator: SyncCoordinator
```

- [ ] **Step 2: Drive the coordinator from the scene** in `body`.

(a) Inject the environment — add after `.environment(session)`:
```swift
                .environment(coordinator)
```

(b) In `.task { … }`, replace the launch-sync line:
```swift
                    if session.isSignedIn { _ = await syncEngine.sync(trigger: .launch) }
```
with:
```swift
                    coordinator.start(trigger: .launch)
```

(c) In the `scenePhase` `onChange`, extend the cases:
```swift
                    case .active:
                        coordinator.enteredForeground()
                        _Concurrency.Task { await store.refreshBadge() }
                    case .background:
                        coordinator.enteredBackground()
                        BackgroundRefresh.schedule()
```

- [ ] **Step 3: Build** — deferred to B11 (SessionStore signature change in B8 must land first to compile). No commit yet.

### Task B8: Refactor `SessionStore` (drop sync state; delegate to coordinator)

**Files:**
- Modify: `App/Auth/SessionStore.swift`

- [ ] **Step 1: Replace the sync-owning bits.**

(a) Delete the two stored properties:
```swift
    private(set) var lastSync: SyncResult?
    private(set) var syncing = false
```

(b) Replace `private let syncEngine: SyncEngine?` with:
```swift
    private let coordinator: SyncCoordinator?
```

(c) Replace the `init` signature + body assignment:
```swift
    init(auth: AuthService, tokenStore: TokenStore, coordinator: SyncCoordinator? = nil) {
        self.auth = auth
        self.tokenStore = tokenStore
        self.coordinator = coordinator
        if tokenStore.load() != nil {
            email = UserDefaults.standard.string(forKey: emailKey)
        }
    }
```

(d) In `signIn`, replace `await runSync(trigger: .signIn)` with:
```swift
            coordinator?.start(trigger: .signIn)   // first sign-in seeds + pulls the user's existing tasks
```

(e) In `signOut`, replace the trailing `_Concurrency.Task { await syncEngine?.resetCursor() }` line with:
```swift
        coordinator?.signedOut()   // tear down + reset cursor; local tasks kept
```

(f) Replace `syncNow()` + delete `runSync(_:)`:
```swift
    /// Manual "Sync Now" (Settings). The launch/after-sign-in triggers fire from the coordinator.
    func syncNow() async { await coordinator?.syncNow() }
```
(remove the entire `private func runSync(trigger:) async { … }` method)

- [ ] **Step 2: Build** — deferred to B11. No commit yet.

### Task B9: `SettingsView` Account section reads the coordinator

**Files:**
- Modify: `App/Settings/SettingsView.swift`

- [ ] **Step 1: Inject the coordinator** — add near the other `@Environment` lines:
```swift
    @Environment(SyncCoordinator.self) private var sync
```

- [ ] **Step 2: Rewrite `accountSection`'s signed-in branch** to use the coordinator for sync state + add the history link. Replace the `Sync Now` button block (the `Button { _Concurrency.Task { await session.syncNow() } } label: { if session.syncing { ProgressView() } else { … } }.disabled(session.syncing)`) with:

```swift
                if let last = sync.lastSync, last.error == nil {
                    LabeledContent(String(localized: "Status"),
                                   value: String(localized: "Synced · \(sync.pendingCount) pending"))
                }
                if let msg = sync.health.message {
                    Text(msg).font(.footnote).foregroundStyle(.secondary)
                }
                Button {
                    _Concurrency.Task { await session.syncNow() }
                } label: {
                    if sync.phase == .syncing {
                        ProgressView()
                    } else {
                        Label(String(localized: "Sync Now"), systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(sync.phase == .syncing)
                NavigationLink {
                    SyncHistoryView(engine: sync.engineForHistory)
                } label: {
                    Label(String(localized: "Sync History"), systemImage: "clock.arrow.circlepath")
                }
```

> `SyncHistoryView` needs the engine. Expose it read-only on the coordinator. Add to `SyncCoordinator`:
> ```swift
>     /// The engine, for the read-only Sync History screen.
>     var engineForHistory: SyncEngine { engine }
> ```

- [ ] **Step 3: Build** — deferred to B11. No commit yet.

### Task B10: Host the chip + pull-to-refresh

**Files:**
- Modify: `App/Matrix/MatrixView.swift`
- Modify: `App/ContentView.swift` (iPad detail)

- [ ] **Step 1: MatrixView — add the chip to the toolbar + `.refreshable` on the List.**

(a) Add the environment + a tab binding for routing taps to Settings. Add near `@Environment(TaskStore.self)`:
```swift
    @Environment(SyncCoordinator.self) private var sync
    @Environment(PaletteController.self) private var paletteEnv   // already imported via `palette`; reuse existing `palette`
```
> NOTE: `MatrixView` already has `@Environment(PaletteController.self) private var palette`. Do NOT re-declare it. Use the existing `palette` for tap-routing (`palette.compactTab = 3`).

(b) Add `.refreshable` to the `List` (after `.listStyle(.insetGrouped)`):
```swift
                .refreshable { await sync.syncNow() }
```

(c) Add the chip to the existing `.toolbar { … }` (after `showCompletedToggle($showCompleted)`):
```swift
                    ToolbarItem(placement: .topBarTrailing) {
                        SyncStatusChip(phase: sync.phase, pendingCount: sync.pendingCount,
                                       health: sync.health) { palette.compactTab = 3 }
                    }
```

- [ ] **Step 2: ContentView (iPad) — chip in the sidebar toolbar + pull-to-refresh on the grid is not applicable; add the chip to the `RegularRootView` sidebar `.toolbar`.**

In `RegularRootView`'s sidebar `.toolbar { ToolbarItem(placement: .topBarLeading) { … } }`, add a trailing item. First inject the coordinator at the top of `RegularRootView`:
```swift
    @Environment(SyncCoordinator.self) private var sync
```
Then add inside the existing `.toolbar { … }`:
```swift
                ToolbarItem(placement: .topBarTrailing) {
                    SyncStatusChip(phase: sync.phase, pendingCount: sync.pendingCount,
                                   health: sync.health) { palette.regularSelection = .settings }
                }
```

- [ ] **Step 3: Build** — deferred to B11. No commit yet.

### Task B11: Group B build + simctl smoke + commit

**Files:** none (regenerate + build + smoke)

- [ ] **Step 1: Regenerate the Xcode project** (picks up `App/Sync/*.swift`)

Run: `cd /Users/vinnycarpenter/Projects/gsd-iosapp && xcodegen generate`
Expected: "Created project at GSD.xcodeproj".

- [ ] **Step 2: Package tests still green**

Run: `cd GSDKit && swift test`
Expected: PASS (all of Group A + B1/B2/B3).

- [ ] **Step 3: Build the app for the simulator**

Run:
```bash
cd /Users/vinnycarpenter/Projects/gsd-iosapp && xcodebuild -project GSD.xcodeproj -scheme GSD \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath .build-app build 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **`. Fix any compile errors from the rewiring (most likely: a missing `@Environment(SyncCoordinator.self)` injection, or a stale `session.syncing`/`session.lastSync` reference — grep `git grep -n "session.syncing\|session.lastSync"` and fix).

- [ ] **Step 4: simctl smoke** (launch + screenshot; same as prior phases)

Run:
```bash
xcrun simctl boot "iPhone 17 Pro" 2>/dev/null; \
xcrun simctl install booted "$(find .build-app -name 'GSD.app' -path '*Debug-iphonesimulator*' | head -1)" && \
xcrun simctl launch booted dev.vinny.gsd && sleep 3 && \
xcrun simctl io booted screenshot /tmp/5d-groupB.png && echo "OK"
```
Expected: launches without crash; screenshot saved. (Signed-out: chip hidden, no crash.)

- [ ] **Step 5: Commit the whole group**

```bash
git add App/ GSDKit/ project.yml GSD.xcodeproj
git commit -m "feat(5d): cadence + debounced push + SyncCoordinator + status chip + history screen + pull-to-refresh"
```

---

## Group C — Realtime SSE (after Probe P1)

### Task C0: Probe P1 — capture the real PocketBase realtime protocol (PREREQUISITE)

**Files:** capture results into `GSDKit/Tests/GSDSyncTests/Fixtures/realtime_connect.txt` + `realtime_event.json` (reference fixtures; the parser tests use inline strings, but keep the observed bytes for the record).

> ⚠ The realtime handshake/envelope is **recalled, not confirmed** (spec §3.3). Do NOT write `PocketBaseRealtime` (C4) until this probe confirms the shapes. This needs a LIVE auth token — the **user** runs it (suggest they type the commands with a `! ` prefix in the session, or paste output).

- [ ] **Step 1: Get a live token** — sign in on the device/sim once, or reuse a known-good PocketBase JWT for `vscarpenter@gmail.com`. Export it: `TOKEN=<jwt>`.

- [ ] **Step 2: Observe the connect event** — open the SSE stream and capture the first event:

```bash
curl -sN -H "Accept: text/event-stream" https://api.vinny.io/api/realtime | head -c 600
```
Record: the event name (expected `PB_CONNECT`), and the `data:` JSON (expected `{"clientId":"..."}`). Note whether `id:` lines appear (for `Last-Event-ID` reconnect).

- [ ] **Step 3: Subscribe + observe a task event** — in one terminal keep the stream open and grab the `clientId`; in another, POST the subscription, then mutate a task on the web app and capture the streamed event:

```bash
# terminal A — capture clientId then keep streaming
curl -sN -H "Accept: text/event-stream" https://api.vinny.io/api/realtime
# terminal B — using the clientId from A:
curl -s -X POST https://api.vinny.io/api/realtime \
  -H "Authorization: $TOKEN" -H "Content-Type: application/json" \
  -d '{"clientId":"<CLIENT_ID>","subscriptions":["tasks"]}'
# now edit a task on the web app; watch terminal A for an event named `tasks`
```
Record: the event `event:` name for collection messages (expected `tasks`), and the `data:` envelope (expected `{"action":"create|update|delete","record":{…§7.1 fields…}}`). **Critically: confirm whether a `delete` event's `record` includes `task_id`** (if not, realtime deletes fall back to the cadence reconcile — that's the documented degrade).

- [ ] **Step 4: Reconcile with the plan** — if any shape differs from the assumptions in C2/C4 (event names, the subscribe body key, the envelope), update C2's `RealtimeEvent` and C4's `PocketBaseRealtime` to match the observed bytes BEFORE implementing. Note deviations in a comment at the top of `PocketBaseRealtime.swift`.

- [ ] **Step 5: Commit the reference fixtures** (if captured)

```bash
git add GSDKit/Tests/GSDSyncTests/Fixtures/realtime_connect.txt GSDKit/Tests/GSDSyncTests/Fixtures/realtime_event.json
git commit -m "test(5d): capture live PocketBase realtime protocol fixtures (Probe P1)"
```

### Task C1: `SSEParser` (pure line-protocol parser)

**Files:**
- Create: `GSDKit/Sources/GSDSync/SSEParser.swift`
- Test: `GSDKit/Tests/GSDSyncTests/SSEParserTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import GSDSync

struct SSEParserTests {
    @Test func dispatchesOnBlankLine() {
        var p = SSEParser()
        #expect(p.feed("event: tasks") == nil)
        #expect(p.feed("data: {\"a\":1}") == nil)
        let e = p.feed("")
        #expect(e == SSEParser.Event(event: "tasks", data: "{\"a\":1}", id: nil))
    }

    @Test func multiLineDataJoinedWithNewline() {
        var p = SSEParser()
        _ = p.feed("data: line1")
        _ = p.feed("data: line2")
        let e = p.feed("")
        #expect(e?.data == "line1\nline2")
    }

    @Test func ignoresCommentHeartbeat() {
        var p = SSEParser()
        #expect(p.feed(":keep-alive") == nil)
        #expect(p.feed("") == nil)        // nothing buffered → no dispatch
    }

    @Test func capturesIdForReconnect() {
        var p = SSEParser()
        _ = p.feed("id: abc")
        _ = p.feed("data: x")
        let e = p.feed("")
        #expect(e?.id == "abc")
        #expect(p.lastEventId == "abc")
    }

    @Test func stripsSingleLeadingSpaceOnly() {
        var p = SSEParser()
        _ = p.feed("data:  two-spaces")   // one space stripped → " two-spaces"
        #expect(p.feed("")?.data == " two-spaces")
    }

    @Test func parsesPBConnect() {
        var p = SSEParser()
        _ = p.feed("event: PB_CONNECT")
        _ = p.feed("data: {\"clientId\":\"c123\"}")
        let e = p.feed("")
        #expect(e?.event == "PB_CONNECT")
        #expect(e?.data == "{\"clientId\":\"c123\"}")
    }
}
```

- [ ] **Step 2: Run — fails**

Run: `cd GSDKit && swift test --filter SSEParserTests`
Expected: FAIL.

- [ ] **Step 3: Write `SSEParser`**

```swift
import Foundation

/// Incremental SSE (`text/event-stream`) line parser. Feed it lines (no trailing newline); it
/// emits a completed `Event` on a blank line. Pure + synchronous → fully unit-testable; the
/// streaming reader (`PocketBaseRealtime`) feeds it lines from `URLSession.bytes.lines`.
struct SSEParser {
    struct Event: Equatable { var event: String?; var data: String; var id: String? }

    private var eventName: String?
    private var dataLines: [String] = []
    private(set) var lastEventId: String?

    mutating func feed(_ line: String) -> Event? {
        if line.isEmpty {
            guard !dataLines.isEmpty || eventName != nil else { return nil }
            let event = Event(event: eventName, data: dataLines.joined(separator: "\n"), id: lastEventId)
            eventName = nil; dataLines = []
            return event
        }
        if line.hasPrefix(":") { return nil }   // comment / heartbeat
        let (field, value) = Self.split(line)
        switch field {
        case "event": eventName = value
        case "data":  dataLines.append(value)
        case "id":    lastEventId = value
        default:      break
        }
        return nil
    }

    /// Split `field: value`; per the SSE spec, exactly one leading space after the colon is removed.
    private static func split(_ line: String) -> (String, String) {
        guard let idx = line.firstIndex(of: ":") else { return (line, "") }
        let field = String(line[..<idx])
        var value = String(line[line.index(after: idx)...])
        if value.hasPrefix(" ") { value.removeFirst() }
        return (field, value)
    }
}
```

- [ ] **Step 4: Run — passes**

Run: `cd GSDKit && swift test --filter SSEParserTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add GSDKit/Sources/GSDSync/SSEParser.swift GSDKit/Tests/GSDSyncTests/SSEParserTests.swift
git commit -m "feat(5d): add pure SSE line-protocol parser"
```

### Task C2: `RealtimeEvent` (decoded `{action, record}` envelope)

**Files:**
- Create: `GSDKit/Sources/GSDSync/RealtimeEvent.swift`
- Test: `GSDKit/Tests/GSDSyncTests/RealtimeEventTests.swift`

> Adjust field names here ONLY if Probe P1 (C0) observed a different envelope.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import GSDSync

struct RealtimeEventTests {
    private func decode(_ s: String) -> RealtimeEvent? {
        try? JSONDecoder().decode(RealtimeEvent.self, from: Data(s.utf8))
    }

    @Test func decodesCreateWithRecord() {
        let e = decode(#"{"action":"create","record":{"task_id":"t1","title":"Hi","client_updated_at":"2024-01-01T00:00:00.000Z"}}"#)
        #expect(e?.action == .create)
        #expect(e?.record?.taskId == "t1")
    }

    @Test func decodesDeleteWithoutTaskIdAsNilRecord() {
        // some delete payloads carry only the PB record id, no task_id → record decodes to nil
        let e = decode(#"{"action":"delete","record":{"id":"rec1","collectionName":"tasks"}}"#)
        #expect(e?.action == .delete)
        #expect(e?.record == nil)
    }

    @Test func unknownActionFailsToDecode() {
        #expect(decode(#"{"action":"frobnicate","record":{"task_id":"t1"}}"#) == nil)
    }
}
```

- [ ] **Step 2: Run — fails**

Run: `cd GSDKit && swift test --filter RealtimeEventTests`
Expected: FAIL.

- [ ] **Step 3: Write `RealtimeEvent`**

```swift
import Foundation

/// One PocketBase realtime message (§7.6): `{action, record}`. The `record` decodes leniently via
/// `PocketBaseTaskRecord` (only `task_id` required) — a delete payload that carries only the PB
/// record id yields a `nil` record, and `applyRealtime` falls back to the cadence reconcile.
struct RealtimeEvent: Decodable {
    enum Action: String, Decodable { case create, update, delete }
    let action: Action
    let record: PocketBaseTaskRecord?

    enum CodingKeys: String, CodingKey { case action, record }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        action = try c.decode(Action.self, forKey: .action)
        record = try? c.decode(PocketBaseTaskRecord.self, forKey: .record)
    }
}
```

- [ ] **Step 4: Run — passes**

Run: `cd GSDKit && swift test --filter RealtimeEventTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add GSDKit/Sources/GSDSync/RealtimeEvent.swift GSDKit/Tests/GSDSyncTests/RealtimeEventTests.swift
git commit -m "feat(5d): add RealtimeEvent envelope decode"
```

### Task C3: `SyncEngine.applyRealtime(rawData:)`

**Files:**
- Modify: `GSDKit/Sources/GSDSync/SyncEngine.swift`
- Test: `GSDKit/Tests/GSDSyncTests/SyncEngineRealtimeTests.swift`

> Public API takes the raw `data` JSON string (keeps `RealtimeEvent`/`PocketBaseTaskRecord` internal). The coordinator forwards each streamed `data` string here.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import GSDSync
import GSDStore
import GSDModel

struct SyncEngineRealtimeTests {
    final class EmptyExecutor: RequestExecuting, @unchecked Sendable {
        func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            (Data(#"{"page":1,"perPage":200,"totalItems":0,"totalPages":1,"items":[]}"#.utf8),
             HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }
    // token with id "u1"
    let token = "eyJhbGciOiJIUzI1NiJ9.eyJpZCI6InUxIiwiZXhwIjo5OTk5OTk5OTk5fQ.x"

    private func make(_ db: AppDatabase, deviceId: String = "dev-A") -> (SyncEngine, GRDBTaskRepository, GRDBSyncQueueRepository) {
        let tasks = GRDBTaskRepository(db); let queue = GRDBSyncQueueRepository(db)
        let eng = SyncEngine(client: PocketBaseClient(baseURL: "https://api.vinny.io", executor: EmptyExecutor()),
                             tasks: tasks, queue: queue,
                             cursor: SyncCursor(defaults: UserDefaults(suiteName: "t.\(UUID().uuidString)")!),
                             deviceId: deviceId, tokenProvider: { self.token },
                             now: { Date(timeIntervalSince1970: 2_000_000_000) }, throttleMs: 0,
                             history: GRDBSyncHistoryRepository(db))
        return (eng, tasks, queue)
    }

    @Test func appliesForeignCreate() async throws {
        let db = try AppDatabase.inMemory(); let (eng, tasks, _) = make(db)
        let json = #"{"action":"create","record":{"task_id":"t1","owner":"u1","title":"From web","urgent":true,"important":false,"quadrant":"urgent-important","client_updated_at":"2033-05-18T03:33:20.000Z","device_id":"dev-B"}}"#
        await eng.applyRealtime(rawData: json)
        let local = try await tasks.fetch(id: "t1")
        #expect(local?.title == "From web")
    }

    @Test func echoFiltersOwnDevice() async throws {
        let db = try AppDatabase.inMemory(); let (eng, tasks, _) = make(db, deviceId: "dev-A")
        let json = #"{"action":"create","record":{"task_id":"t1","owner":"u1","title":"echo","client_updated_at":"2033-05-18T03:33:20.000Z","device_id":"dev-A"}}"#
        await eng.applyRealtime(rawData: json)
        #expect(try await tasks.fetch(id: "t1") == nil)     // own device → skipped
    }

    @Test func emptyDeviceIdIsApplied() async throws {
        let db = try AppDatabase.inMemory(); let (eng, tasks, _) = make(db, deviceId: "dev-A")
        let json = #"{"action":"create","record":{"task_id":"t1","owner":"u1","title":"web no-dev","client_updated_at":"2033-05-18T03:33:20.000Z","device_id":""}}"#
        await eng.applyRealtime(rawData: json)
        #expect(try await tasks.fetch(id: "t1") != nil)      // empty device_id → foreign → applied
    }

    @Test func ownerMismatchSkipped() async throws {
        let db = try AppDatabase.inMemory(); let (eng, tasks, _) = make(db)
        let json = #"{"action":"create","record":{"task_id":"t1","owner":"someone-else","title":"x","client_updated_at":"2033-05-18T03:33:20.000Z","device_id":"dev-B"}}"#
        await eng.applyRealtime(rawData: json)
        #expect(try await tasks.fetch(id: "t1") == nil)
    }

    @Test func lwwSkipsOlderRemote() async throws {
        let db = try AppDatabase.inMemory(); let (eng, tasks, _) = make(db)
        let fresh = Task(id: "t1", title: "local fresh", urgent: false, important: false,
                         createdAt: Date(timeIntervalSince1970: 9_000_000_000), updatedAt: Date(timeIntervalSince1970: 9_000_000_000))
        try await tasks.upsert(fresh)
        let json = #"{"action":"update","record":{"task_id":"t1","owner":"u1","title":"old remote","client_updated_at":"2001-01-01T00:00:00.000Z","device_id":"dev-B"}}"#
        await eng.applyRealtime(rawData: json)
        #expect(try await tasks.fetch(id: "t1")?.title == "local fresh")   // local newer → kept
    }

    @Test func deleteRemovesTask() async throws {
        let db = try AppDatabase.inMemory(); let (eng, tasks, _) = make(db)
        try await tasks.upsert(Task(id: "t1", title: "doomed", urgent: false, important: false,
                                    createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1)))
        let json = #"{"action":"delete","record":{"task_id":"t1","owner":"u1","device_id":"dev-B"}}"#
        await eng.applyRealtime(rawData: json)
        #expect(try await tasks.fetch(id: "t1") == nil)
    }

    @Test func deleteSkippedWhenTaskHasPendingQueueItem() async throws {
        let db = try AppDatabase.inMemory(); let (eng, tasks, queue) = make(db)
        try await tasks.upsert(Task(id: "t1", title: "just created locally", urgent: false, important: false,
                                    createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1)))
        try await queue.enqueue(SyncQueueItem(id: "q1", taskId: "t1", operation: .create, timestamp: 1))
        let json = #"{"action":"delete","record":{"task_id":"t1","owner":"u1","device_id":"dev-B"}}"#
        await eng.applyRealtime(rawData: json)
        #expect(try await tasks.fetch(id: "t1") != nil)   // queued → not dropped by realtime
    }

    @Test func malformedDoesNotCrash() async throws {
        let db = try AppDatabase.inMemory(); let (eng, _, _) = make(db)
        await eng.applyRealtime(rawData: "not json")
        await eng.applyRealtime(rawData: #"{"action":"create"}"#)   // no record
        #expect(Bool(true))   // reached here without throwing
    }
}
```

- [ ] **Step 2: Run — fails**

Run: `cd GSDKit && swift test --filter SyncEngineRealtimeTests`
Expected: FAIL (`applyRealtime` undefined).

- [ ] **Step 3: Add `applyRealtime`** to `SyncEngine` (place after `pull`/`push`, before `sync`)

```swift
    /// Apply one realtime (SSE) message (§7.6). Same rules as pull: write via the repo directly (no
    /// enqueue, no re-stamp), LWW vs local, device-local preserved by the mapper merge. Echo-filters
    /// our own `device_id` (non-empty match only), enforces the owner check, and a realtime DELETE for
    /// a task with a pending/failed queue item is skipped (queue-aware, like reconcile). Malformed or
    /// task_id-less payloads are skipped (the cadence safety-net reconciles).
    public func applyRealtime(rawData: String) async {
        guard let data = rawData.data(using: .utf8),
              let event = try? JSONDecoder().decode(RealtimeEvent.self, from: data),
              let record = event.record else { return }
        if !record.deviceId.isEmpty && record.deviceId == deviceId { return }   // echo-filter
        if !record.owner.isEmpty, let token = try? await tokenProvider(), let t = token,
           let owner = JWT.userId(t), record.owner != owner { return }          // owner check
        switch event.action {
        case .create, .update:
            guard let remoteUpdated = WireDate.parse(record.clientUpdatedAt) else { return }
            let local = try? await tasks.fetch(id: record.taskId)
            let decision = LWW.resolve(localUpdatedAt: local?.updatedAt, remoteClientUpdatedAt: remoteUpdated)
            guard local == nil || decision == .takeRemote else { return }
            try? await tasks.upsert(TaskWireMapper.toDomain(record, mergingInto: local ?? nil))
        case .delete:
            let queued = (try? await queue.allTaskIds()) ?? []
            if queued.contains(record.taskId) { return }   // queue-aware: don't drop a locally-pending task
            try? await tasks.delete(id: record.taskId)
        }
    }
```

> NOTE: `local ?? nil` is just `local` — write `mergingInto: local` (the `?? nil` is redundant; `local` is already `Task?`).

- [ ] **Step 4: Run — passes**

Run: `cd GSDKit && swift test --filter SyncEngineRealtimeTests`
Expected: PASS (8 tests).

- [ ] **Step 5: Commit**

```bash
git add GSDKit/Sources/GSDSync/SyncEngine.swift GSDKit/Tests/GSDSyncTests/SyncEngineRealtimeTests.swift
git commit -m "feat(5d): SyncEngine.applyRealtime (echo-filter, LWW, queue-aware delete)"
```

### Task C4: `PocketBaseRealtime` (streaming subscription client)

**Files:**
- Create: `GSDKit/Sources/GSDSync/PocketBaseRealtime.swift`

> The streaming itself is verified at the live gate (A74/L1–L4), not unit-tested — `URLSession.bytes` streaming has no in-process fake here. The protocol-shaping pieces it depends on (`SSEParser`, `RealtimeEvent`) ARE unit-tested. Match the connect/subscribe shapes to Probe P1's observed bytes.

- [ ] **Step 1: Create the file**

```swift
import Foundation

/// Minimal PocketBase realtime (SSE) client over `URLSession.bytes` (§7.6). Foundation-only.
/// Protocol (confirm at Probe P1): `GET /api/realtime` streams a `PB_CONNECT` event whose data is
/// `{"clientId":"…"}`; `POST /api/realtime {clientId, subscriptions:["tasks"]}` with `Authorization`
/// subscribes; subsequent events (named `tasks`) carry `{"action","record"}` in their `data`.
public final class PocketBaseRealtime: Sendable {
    private let baseURL: String
    private let session: URLSession

    public init(baseURL: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    /// Yields the `data` JSON string of each `tasks` event. Throws on connect/subscribe failure (the
    /// coordinator catches + retries with backoff). Cancelling the consuming task disconnects.
    public func events(token: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let streamTask = _Concurrency.Task { [baseURL, session] in
                do {
                    var req = URLRequest(url: URL(string: baseURL + "/api/realtime")!)
                    req.timeoutInterval = .infinity
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    let (bytes, response) = try await session.bytes(for: req)
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                        throw PocketBaseError.network("realtime connect failed")
                    }
                    var parser = SSEParser()
                    var subscribed = false
                    for try await line in bytes.lines {
                        if _Concurrency.Task.isCancelled { break }
                        guard let event = parser.feed(line) else { continue }
                        if event.event == "PB_CONNECT" || event.data.contains("\"clientId\"") {
                            if let clientId = Self.clientId(from: event.data) {
                                try await Self.subscribe(baseURL: baseURL, session: session,
                                                         clientId: clientId, token: token)
                                subscribed = true
                            }
                            continue
                        }
                        if subscribed, event.event == "tasks" || event.data.contains("\"action\"") {
                            continuation.yield(event.data)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in streamTask.cancel() }
        }
    }

    private static func subscribe(baseURL: String, session: URLSession, clientId: String, token: String) async throws {
        var req = URLRequest(url: URL(string: baseURL + "/api/realtime")!)
        req.httpMethod = "POST"
        req.setValue(token, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["clientId": clientId, "subscriptions": ["tasks"]])
        let (_, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw PocketBaseError.network("realtime subscribe failed")
        }
    }

    private static func clientId(from data: String) -> String? {
        guard let d = data.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return obj["clientId"] as? String
    }
}
```

- [ ] **Step 2: Build the package**

Run: `cd GSDKit && swift build`
Expected: succeeds.

- [ ] **Step 3: Commit**

```bash
git add GSDKit/Sources/GSDSync/PocketBaseRealtime.swift
git commit -m "feat(5d): add PocketBaseRealtime SSE subscription client"
```

### Task C5: Wire SSE into `SyncCoordinator` + `GSDApp`

**Files:**
- Modify: `App/Sync/SyncCoordinator.swift`
- Modify: `App/GSDApp.swift`

- [ ] **Step 1: Extend `SyncCoordinator`** to own the SSE lifecycle.

(a) Add stored deps + the SSE task. Add after `private let signedIn:`:
```swift
    private let realtime: PocketBaseRealtime
    private let tokenProvider: @Sendable () async -> String?

    @ObservationIgnored private var sseTask: _Concurrency.Task<Void, Never>?
```

(b) Update `init` to take them:
```swift
    init(engine: SyncEngine, realtime: PocketBaseRealtime,
         tokenProvider: @escaping @Sendable () async -> String?,
         signedIn: @escaping @MainActor () -> Bool) {
        self.engine = engine
        self.realtime = realtime
        self.tokenProvider = tokenProvider
        self.signedIn = signedIn
    }
```

(c) In `start(trigger:)` and `enteredForeground()`, add `startSSE()` after `startCadence()`:
```swift
        startCadence()
        startSSE()
```

(d) In `stop()` and `enteredBackground()`, cancel the SSE task. Add after the `cadenceTask?.cancel()` line in each:
```swift
        sseTask?.cancel(); sseTask = nil
```

(e) Add the SSE loop (place near `startCadence`):
```swift
    /// Foreground-only realtime: stream `tasks` events → `applyRealtime`; on stream end/error run a
    /// full sync (catch missed events) and reconnect with capped backoff while active + signed-in.
    private func startSSE() {
        sseTask?.cancel()
        sseTask = _Concurrency.Task { [weak self] in
            var backoff = 1.0
            while let self, !_Concurrency.Task.isCancelled, self.signedIn(), self.active {
                guard let token = await self.tokenProvider() else { break }
                do {
                    for try await data in self.realtime.events(token: token) {
                        if _Concurrency.Task.isCancelled { return }
                        await self.engine.applyRealtime(rawData: data)
                        await self.refreshStatus()
                    }
                } catch { /* fall through to reconnect */ }
                if _Concurrency.Task.isCancelled { return }
                await self.runSync(trigger: .foreground)   // reconnect → catch missed events
                try? await _Concurrency.Task.sleep(for: .seconds(min(backoff, 30)))
                backoff = min(backoff * 2, 30)
            }
        }
    }
```

> `refreshStatus()` is `private` — `startSSE` is in the same type, so the call is fine.

- [ ] **Step 2: Update `GSDApp`** to construct the realtime client + pass the new coordinator args.

(a) After the `let syncEngine = SyncEngine(…)` block, before the coordinator line, add:
```swift
        let realtime = PocketBaseRealtime(baseURL: AuthConfig.live.baseURL)
```

(b) Replace the coordinator construction line with:
```swift
        let coordinator = SyncCoordinator(
            engine: syncEngine, realtime: realtime,
            tokenProvider: { try? await authService.validToken() },
            signedIn: { tokenStore.load() != nil })
```

- [ ] **Step 3: Regenerate + build**

Run:
```bash
cd /Users/vinnycarpenter/Projects/gsd-iosapp && xcodegen generate && \
xcodebuild -project GSD.xcodeproj -scheme GSD \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath .build-app build 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Package tests still green**

Run: `cd GSDKit && swift test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add App/ GSD.xcodeproj
git commit -m "feat(5d): wire SSE realtime into SyncCoordinator + GSDApp"
```

### Task C6: Group C simctl smoke

- [ ] **Step 1: Launch + screenshot** (signed-out path must not crash; SSE only starts when signed in)

Run:
```bash
xcrun simctl boot "iPhone 17 Pro" 2>/dev/null; \
xcrun simctl install booted "$(find .build-app -name 'GSD.app' -path '*Debug-iphonesimulator*' | head -1)" && \
xcrun simctl launch booted dev.vinny.gsd && sleep 3 && \
xcrun simctl io booted screenshot /tmp/5d-groupC.png && echo "OK"
```
Expected: launches without crash. (Real SSE behavior is validated at the A74 live gate, not the sim.)

- [ ] **Step 2: No new commit** (covered by C5).

---

## Group D — Destructive ops + confirmations

### Task D1: `isErasing` pull-suppression gate + `eraseAllRemote()` + `flushDeletes()`

**Files:**
- Modify: `GSDKit/Sources/GSDSync/SyncEngine.swift`
- Test: `GSDKit/Tests/GSDSyncTests/SyncEngineEraseTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import GSDSync
import GSDStore
import GSDModel

struct SyncEngineEraseTests {
    // Returns a one-task remote index for GET; records writes (DELETE/POST/PATCH) otherwise.
    final class DeleteExecutor: RequestExecuting, @unchecked Sendable {
        var indexJSON = #"{"page":1,"perPage":200,"totalItems":1,"totalPages":1,"items":[{"id":"rec1","task_id":"t1","client_updated_at":"2001-01-01T00:00:00.000Z"}]}"#
        private(set) var writes: [(method: String, path: String)] = []
        func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let m = request.httpMethod ?? "GET"
            if m == "GET" {
                return (Data(indexJSON.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            writes.append((m, request.url!.path))
            return (Data(#"{"id":"rec1","task_id":"t1"}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: m == "DELETE" ? 204 : 200, httpVersion: nil, headerFields: nil)!)
        }
    }
    let token = "eyJhbGciOiJIUzI1NiJ9.eyJpZCI6InUxIiwiZXhwIjo5OTk5OTk5OTk5fQ.x"

    private func make(_ db: AppDatabase, _ exec: RequestExecuting)
        -> (SyncEngine, GRDBTaskRepository, GRDBSyncQueueRepository) {
        let tasks = GRDBTaskRepository(db); let queue = GRDBSyncQueueRepository(db)
        let eng = SyncEngine(client: PocketBaseClient(baseURL: "https://api.vinny.io", executor: exec),
                             tasks: tasks, queue: queue,
                             cursor: SyncCursor(defaults: UserDefaults(suiteName: "t.\(UUID().uuidString)")!),
                             deviceId: "dev-A", tokenProvider: { self.token },
                             now: { Date(timeIntervalSince1970: 2_000_000_000) }, throttleMs: 0,
                             history: GRDBSyncHistoryRepository(db))
        return (eng, tasks, queue)
    }

    @Test func eraseAllRemoteEnqueuesAndDeletesEveryLocalTask() async throws {
        let db = try AppDatabase.inMemory(); let exec = DeleteExecutor()
        let (eng, tasks, queue) = make(db, exec)
        try await tasks.upsert(Task(id: "t1", title: "x", urgent: false, important: false,
                                    createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1)))
        let result = await eng.eraseAllRemote()
        #expect(result.pushed == 1)
        #expect(exec.writes.contains { $0.method == "DELETE" })
        #expect(try await queue.pending().isEmpty)        // delete drained
    }

    @Test func eraseAllRemoteNoOpsWhenSignedOut() async throws {
        let db = try AppDatabase.inMemory()
        let tasks = GRDBTaskRepository(db); let queue = GRDBSyncQueueRepository(db)
        try await tasks.upsert(Task(id: "t1", title: "x", urgent: false, important: false,
                                    createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1)))
        let eng = SyncEngine(client: PocketBaseClient(baseURL: "https://api.vinny.io", executor: DeleteExecutor()),
                             tasks: tasks, queue: queue,
                             cursor: SyncCursor(defaults: UserDefaults(suiteName: "t.\(UUID().uuidString)")!),
                             deviceId: "dev-A", tokenProvider: { nil },
                             now: { Date(timeIntervalSince1970: 2_000_000_000) }, throttleMs: 0,
                             history: GRDBSyncHistoryRepository(db))
        let result = await eng.eraseAllRemote()
        #expect(result.notSignedIn)
        #expect(try await queue.pending().isEmpty)        // signed out → no deletes enqueued
    }

    @Test func flushDeletesDrainsPendingDeletes() async throws {
        let db = try AppDatabase.inMemory(); let exec = DeleteExecutor()
        let (eng, _, queue) = make(db, exec)
        try await queue.enqueue(SyncQueueItem(id: "q1", taskId: "t1", operation: .delete, timestamp: 1))
        let result = await eng.flushDeletes()
        #expect(result.pushed == 1)
        #expect(exec.writes.contains { $0.method == "DELETE" })
    }

    @Test func pullSuppressedWhileErasing() async throws {
        let db = try AppDatabase.inMemory(); let exec = DeleteExecutor()  // index has "t1"
        let (eng, tasks, _) = make(db, exec)
        await eng.setErasing(true)
        let (applied, conflicts, maxApplied) = try await eng.pull(token: token, since: "1970-01-01T00:00:00.000Z")
        #expect(applied == 0 && conflicts == 0 && maxApplied == nil)
        #expect(try await tasks.fetch(id: "t1") == nil)   // gate prevented the upsert
    }
}
```

- [ ] **Step 2: Run — fails**

Run: `cd GSDKit && swift test --filter SyncEngineEraseTests`
Expected: FAIL (`eraseAllRemote`/`flushDeletes`/`setErasing` undefined).

- [ ] **Step 3: Edit `SyncEngine.swift`**

(a) Add the gate state next to `isSyncing`:
```swift
    private var isSyncing = false
    private var isErasing = false      // §3.4: suppresses pull during a destructive erase/replace drain
```

(b) Guard `pull` — add as the first line of `pull(token:since:)`:
```swift
        if isErasing { return (0, 0, nil) }       // §3.4 pull-suppression gate
```

(c) Add the destructive methods + the test seam (place after `pushNow`):
```swift
    /// §3.4 erase-all remote wipe: while pull is suppressed, enqueue a delete for every local task,
    /// then drain (push-only) so a concurrent sync can't re-add them mid-flight. Signed-out → no-op
    /// (the App still clears local). The App calls this BEFORE `TaskStore.eraseAllData`.
    public func eraseAllRemote() async -> SyncResult {
        guard !isSyncing else { return SyncResult(skipped: true) }
        isSyncing = true; isErasing = true
        defer { isSyncing = false; isErasing = false }
        var result = SyncResult()
        let token: String
        do {
            guard let t = try await tokenProvider() else { result.notSignedIn = true; return result }
            token = t
        } catch { result.notSignedIn = true; return result }
        guard let owner = JWT.userId(token) else {
            result.error = "Could not derive owner from auth token"; return result
        }
        if let all = try? await tasks.fetchAll() {
            for task in all {
                try? await queue.enqueue(SyncQueueItem(id: UUID().uuidString, taskId: task.id,
                    operation: .delete, timestamp: Int(now().timeIntervalSince1970 * 1000)))
            }
        }
        let start = now()
        do {
            let (pushed, failed) = try await push(token: token, owner: owner)
            result.pushed = pushed; result.failed = failed
            await record(trigger: .manual, result: result, conflicts: 0, start: start)
        } catch {
            result.error = String("\(error)".prefix(200))
            await record(trigger: .manual, result: result, conflicts: 0, start: start)
        }
        return result
    }

    /// §3.4 drain pending deletes (from a destructive import-replace) with pull suppressed. The
    /// deletes were already enqueued by `TaskStore.importTasks(replace)`; this just pushes them safely.
    public func flushDeletes() async -> SyncResult {
        guard !isSyncing else { return SyncResult(skipped: true) }
        isSyncing = true; isErasing = true
        defer { isSyncing = false; isErasing = false }
        var result = SyncResult()
        let token: String
        do {
            guard let t = try await tokenProvider() else { result.notSignedIn = true; return result }
            token = t
        } catch { result.notSignedIn = true; return result }
        guard let owner = JWT.userId(token) else {
            result.error = "Could not derive owner from auth token"; return result
        }
        let start = now()
        do {
            let (pushed, failed) = try await push(token: token, owner: owner)
            result.pushed = pushed; result.failed = failed
            await record(trigger: .manual, result: result, conflicts: 0, start: start)
        } catch {
            result.error = String("\(error)".prefix(200))
            await record(trigger: .manual, result: result, conflicts: 0, start: start)
        }
        return result
    }

    /// Test seam (§3.4): set the pull-suppression gate directly so the suppression is unit-testable.
    func setErasing(_ value: Bool) { isErasing = value }
```

- [ ] **Step 4: Run — passes**

Run: `cd GSDKit && swift test --filter SyncEngineEraseTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add GSDKit/Sources/GSDSync/SyncEngine.swift GSDKit/Tests/GSDSyncTests/SyncEngineEraseTests.swift
git commit -m "feat(5d): isErasing pull-suppression gate + eraseAllRemote + flushDeletes"
```

### Task D2: `TaskStore.importTasks(replace)` enqueues deletes for cleared tasks

**Files:**
- Modify: `GSDKit/Sources/GSDStore/TaskStore.swift`
- Test: `GSDKit/Tests/GSDStoreTests/TaskStoreDataTests.swift`

- [ ] **Step 1: Write the failing test** (append to `TaskStoreDataTests`; reuse its existing `RecordingQueue`/store helper — if this file has none, mirror `TaskStoreEnqueueTests`' `RecordingQueue`)

```swift
@Test func replaceEnqueuesDeletesForClearedTasks() async throws {
    let q = RecordingQueue(); let store = try makeStore(q)
    // seed two existing tasks A, B
    try await store.create(Task(id: "A", title: "a", urgent: false, important: false,
                                createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1)))
    try await store.create(Task(id: "B", title: "b", urgent: false, important: false,
                                createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1)))
    q.ops.removeAll()   // ignore the create ops; focus on the import
    // import-replace with only B and a new C
    let payload = try TaskExport.encode(TaskExport(tasks: [
        Task(id: "B", title: "b2", urgent: false, important: false, createdAt: Date(timeIntervalSince1970: 2), updatedAt: Date(timeIntervalSince1970: 2)),
        Task(id: "C", title: "c", urgent: false, important: false, createdAt: Date(timeIntervalSince1970: 2), updatedAt: Date(timeIntervalSince1970: 2)),
    ], exportedAt: Date(timeIntervalSince1970: 2)))
    _ = try await store.importTasks(payload, mode: .replace)
    // A was cleared → a .delete enqueued; B,C → .update
    #expect(q.ops.contains { $0.op == .delete && $0.taskId == "A" })
    #expect(q.ops.contains { $0.op == .update && $0.taskId == "B" })
    #expect(q.ops.contains { $0.op == .update && $0.taskId == "C" })
    #expect(!q.ops.contains { $0.op == .delete && $0.taskId == "B" })
}
```

> If `RecordingQueue`'s recorded tuple uses different field names, adapt the assertions to match (the existing enqueue tests define its shape).

- [ ] **Step 2: Run — fails**

Run: `cd GSDKit && swift test --filter TaskStoreDataTests`
Expected: FAIL (no delete enqueued for "A").

- [ ] **Step 3: Edit `importTasks`** — the `.replace` case. Replace it with:

```swift
        case .replace:
            let existingIDs = Set(try await repository.fetchAll().map(\.id))
            let result = try TaskImporter.replace(from: data)
            let importedIDs = Set(result.tasks.map(\.id))
            let now = clock()
            let stamped = result.tasks.map { task -> Task in
                var t = task; t.updatedAt = now; return t
            }
            try await repository.replaceAll(stamped)
            for t in stamped { await enqueue(t.id, .update, payload: t) }
            // §3.4: cleared-but-not-imported tasks must be deleted remotely too (the App drains via
            // SyncCoordinator.flushAfterReplace under the pull-suppression gate).
            for removed in existingIDs.subtracting(importedIDs) { await enqueue(removed, .delete, payload: nil) }
            return result
```

- [ ] **Step 4: Run — passes**

Run: `cd GSDKit && swift test --filter TaskStoreDataTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add GSDKit/Sources/GSDStore/TaskStore.swift GSDKit/Tests/GSDStoreTests/TaskStoreDataTests.swift
git commit -m "feat(5d): import-replace enqueues deletes for cleared tasks"
```

### Task D3: Coordinator destructive methods + `DataStorageView` confirmations

**Files:**
- Modify: `App/Sync/SyncCoordinator.swift`
- Modify: `App/Settings/DataStorageView.swift`

- [ ] **Step 1: Add the orchestration methods to `SyncCoordinator`** (place under `// MARK: Triggers`). It already imports `GSDStore` (so `TaskStore` is in scope):

```swift
    /// §3.4 erase everywhere: wipe remote (pull suppressed) THEN clear local. Signed-out → local only.
    func eraseEverywhere(store: TaskStore) async {
        _ = await engine.eraseAllRemote()
        try? await store.eraseAllData()
        await refreshStatus()
    }

    /// §3.4 after a destructive import-replace: drain the cleared-task deletes under the gate.
    func flushAfterReplace() async {
        _ = await engine.flushDeletes()
        await refreshStatus()
    }
```

> `refreshStatus()` is `private` — these methods are in the same type, so the call compiles.

- [ ] **Step 2: Update `DataStorageView`** — inject the coordinator + reroute the two destructive paths.

(a) Add the environment (after `@Environment(TaskStore.self) private var store`):
```swift
    @Environment(SyncCoordinator.self) private var sync
```

(b) Reword the import-mode dialog message to flag cross-device effect. Replace the `.confirmationDialog`'s `message:` `Text(...)` with:
```swift
            Text(String(localized: "Merge keeps your current tasks and adds the imported ones. Replace deletes your current tasks first — and, if you're signed in, deletes them on all your devices."))
```

(c) After a successful **replace** import, drain under the gate. In `runImport(mode:)`, after the `let result = try await store.importTasks(data, mode: mode)` line, add:
```swift
                if mode == .replace { await sync.flushAfterReplace() }
```

(d) Reword the erase alert message + route through the coordinator. Replace the erase alert's `message:` `Text(...)` with:
```swift
            Text(String(localized: "This cannot be undone and, if you're signed in, erases your tasks on all your devices. Type RESET to confirm. Consider exporting first."))
```
and replace the erase action body (`_Concurrency.Task { try? await store.eraseAllData(); statusMessage = … }`) with:
```swift
                _Concurrency.Task {
                    await sync.eraseEverywhere(store: store)
                    statusMessage = String(localized: "All data erased.")
                }
```

- [ ] **Step 3: Regenerate + build**

Run:
```bash
cd /Users/vinnycarpenter/Projects/gsd-iosapp && xcodegen generate && \
xcodebuild -project GSD.xcodeproj -scheme GSD \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath .build-app build 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add App/ GSD.xcodeproj
git commit -m "feat(5d): cross-device erase + import-replace deletion with confirmations"
```

### Task D4: Group D simctl smoke

- [ ] **Step 1: Launch + screenshot**

Run:
```bash
xcrun simctl boot "iPhone 17 Pro" 2>/dev/null; \
xcrun simctl install booted "$(find .build-app -name 'GSD.app' -path '*Debug-iphonesimulator*' | head -1)" && \
xcrun simctl launch booted dev.vinny.gsd && sleep 3 && \
xcrun simctl io booted screenshot /tmp/5d-groupD.png && echo "OK"
```
Expected: launches without crash; Settings → Data & Storage shows the reworded confirmations.

- [ ] **Step 2: No new commit** (covered by D3).

---

## Final — Review, smoke (both sims), live gate, merge

### Task F1: Full suite + combined review

- [ ] **Step 1: Whole package suite green**

Run: `cd GSDKit && swift test`
Expected: PASS — prior 351 + all of Groups A–D (~ +40 tests).

- [ ] **Step 2: Request code review** — use `superpowers:requesting-code-review` (or `/code-review high`) over the branch diff vs `main`. Focus reviewers on: the destructive-op ordering (§3.4), the realtime echo-filter/owner/queue-aware-delete semantics, and the SessionStore→SyncCoordinator refactor (no regression of the 5c launch/sign-in/Sync-Now triggers). Address findings via `superpowers:receiving-code-review`.

### Task F2: Build + simctl smoke on BOTH sims

- [ ] **Step 1: iPhone**

Run:
```bash
cd /Users/vinnycarpenter/Projects/gsd-iosapp && xcodegen generate && \
xcodebuild -project GSD.xcodeproj -scheme GSD -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath .build-app build 2>&1 | tail -5 && \
xcrun simctl boot "iPhone 17 Pro" 2>/dev/null; \
xcrun simctl install booted "$(find .build-app -name 'GSD.app' -path '*Debug-iphonesimulator*' | head -1)" && \
xcrun simctl launch booted dev.vinny.gsd && sleep 3 && xcrun simctl io booted screenshot /tmp/5d-iphone.png && echo OK
```
Expected: BUILD SUCCEEDED + launches.

- [ ] **Step 2: iPad** — repeat with `-destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)'` + `-derivedDataPath .build-app-ipad`, boot/install/launch that sim, screenshot `/tmp/5d-ipad.png`. Expected: launches; sidebar shows the chip slot.

### Task F3: A74 LIVE GATE (manual, owner's device + web — GATES MERGE)

> Not merge-on-unit-green. Run on a real iPhone signed in as `vscarpenter@gmail.com`, with the web app open for the same account. Confirm Probe P1's shapes held.

- [ ] **L1** create web→phone and phone→web appear within seconds (no manual sync).
- [ ] **L2** update both directions + LWW (edit same task on both; newest wins).
- [ ] **L3** delete propagates; echo-filter (your own phone edit isn't double-applied).
- [ ] **L4** background the app, change tasks on web, foreground → missed events caught.
- [ ] **L5** kill connectivity to break SSE → the 2-min cadence still converges; restore network → reconnect + sync.
- [ ] **L6** Erase All Data on phone empties web; import-replace on phone propagates the deletions to web.
- [ ] **L7** status chip shows syncing/pending/error; pull-to-refresh works; Sync History screen populated with correct counts; an offline state shows the health message.

### Task F4: Finish the branch (only after F3 passes)

- [ ] **Step 1: Update the spec status + the deferred-items note** in `docs/specs/2026-06-02-phase-5d-realtime-status.md` (mark implemented; note any P1 protocol deviations). Commit.
- [ ] **Step 2: Merge** — use `superpowers:finishing-a-development-branch`. Fast-forward to `main` (linear history, per the project convention), tag `phase-5d-realtime-status`, push to `origin/main`, delete the feature branch (local + origin).
- [ ] **Step 3: Update memory** — `gsd-ios-project-state.md`: Phase 5 COMPLETE (5a–5d); record SSE protocol as confirmed (P1), the SessionStore→SyncCoordinator refactor, and any live-gate learnings.

---

## Plan Self-Review (run by the author against the spec)

**1. Spec coverage** — every §3/§6 requirement maps to a task:
- §3.1 coordinator/engine split → B4 (+ B7/B8 wiring). §3.2 `applyRealtime`/`pushNow`/`eraseAllRemote`/history → C3/B1/D1/A7. New `SyncTrigger` cases → A7. §3.3 SSE (`PocketBaseRealtime`/`SSEParser`/`RealtimeEvent`) → C1/C2/C4 (+ Probe P1 = C0). §3.4 destructive ordering (`isErasing` gate) → D1/D2/D3. §3.5 history table/repo/health → A1–A6. §3.6 status UI (chip/Settings/history screen/pull-to-refresh) → B5/B6/B9/B10. A65–A73 → Groups A–D tasks; A74 live gate → F3.
- **Deferred items folded in** (owner's call): import-replace remote-deletion → D2/D3; erase-all remote wipe → D1/D3. ✓

**2. Placeholder scan** — no "TBD/TODO/handle edge cases"; every code step shows full code; every test step shows the assertions. ✓

**3. Type consistency** — `SyncHistoryEntry`(.Status/.TriggeredBy), `SyncHistoryStats`, `SyncHistoryRepository`(insert/recent/stats/prune), `SyncHealth`(.evaluate/.Level), `SyncTrigger`(+foreground/periodic/networkRegained/mutation), `SyncEngine`(applyRealtime(rawData:)/pushNow/health(online:)/pendingCount/recentHistory/historyStats/eraseAllRemote/flushDeletes/setErasing), `SyncCoordinator`(start(trigger:)/stop/signedOut/enteredForeground/enteredBackground/syncNow/scheduleDebouncedPush/eraseEverywhere(store:)/flushAfterReplace/engineForHistory) — names used consistently across tasks. `SyncEngine.init` gains a defaulted `history:` (A7) so existing call sites compile until wired in B7. ✓

**4. Known watch-outs for the implementer:**
- `pull`'s return tuple changed in A7 (now 3-tuple) — its only caller is `sync()`; fix any direct test call sites.
- The coordinator `init` signature changes in C5 (adds `realtime`/`tokenProvider`) — GSDApp updated in the same task.
- App-layer files don't compile standalone; the first real build is B11 (after `xcodegen generate`).
- Probe P1 (C0) is a hard prerequisite for C4 — do not code the SSE client from memory.
