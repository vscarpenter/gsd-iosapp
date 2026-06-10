# Deferred Sync & Store Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the five deferred fixes from `docs/superpowers/specs/2026-06-10-deferred-sync-hardening-design.md` — reconcile race (E), observer retry (D), reminder resync (A), server-stamped pull cursor (B), cross-account sign-in prompt (C).

**Architecture:** All logic lands in the GSDKit package with unit tests; the app layer gets only glue (a debounced resyncer, SessionStore routing, one dialog). Implementation order E → D → A → B → C (risk order). Owner confirmed (2026-06-10) the live `tasks` collection has/will have the PB autodate `updated` field before the Fix B live gate.

**Tech Stack:** Swift 6 (strict concurrency), SwiftPM (`cd GSDKit && swift test`), GRDB, Swift Testing (`@Test`/`#expect`). Verify app-layer changes with `xcodegen generate` + `xcodebuild` (iPhone 17 Pro / iPad Pro 13-inch (M5) sims). All test commands run from `GSDKit/`.

---

### Task 1: Fix E — enqueue-before-upsert + reconcile read order

**Files:**
- Modify: `GSDKit/Sources/GSDStore/TaskStore.swift` (mutation paths + `enqueue`)
- Modify: `GSDKit/Sources/GSDSync/SyncEngine.swift` (`reconcileDeletions`)
- Create: `GSDKit/Tests/GSDStoreTests/TaskStoreWriteOrderTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
import GSDModel
@testable import GSDStore

/// Pins the Fix-E ordering invariant: the sync-queue item is persisted BEFORE the task row
/// (so deletion-reconcile can never see an unprotected new task), and an upsert failure
/// removes the orphaned queue item (an unpersisted task must not push a ghost create).
@MainActor
struct TaskStoreWriteOrderTests {
    final class EventLog: @unchecked Sendable { var events: [String] = [] }

    final class LoggingRepository: TaskRepository, @unchecked Sendable {
        let log: EventLog
        var failUpsert = false
        struct Boom: Error {}
        init(log: EventLog) { self.log = log }
        func upsert(_ task: Task) async throws {
            log.events.append("upsert")
            if failUpsert { throw Boom() }
        }
        func fetchAll() async throws -> [Task] { [] }
        func fetch(id: String) async throws -> Task? { nil }
        func delete(id: String) async throws { log.events.append("delete") }
        func replaceAll(_ tasks: [Task]) async throws { log.events.append("replaceAll") }
        func observeAll() -> AsyncThrowingStream<[Task], Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    final class LoggingQueue: SyncQueueRepository, @unchecked Sendable {
        let log: EventLog
        var items: [SyncQueueItem] = []
        init(log: EventLog) { self.log = log }
        func enqueue(_ item: SyncQueueItem) async throws { log.events.append("enqueue"); items.append(item) }
        func pending() async throws -> [SyncQueueItem] { items }
        func update(_ item: SyncQueueItem) async throws {}
        func remove(id: String) async throws { log.events.append("remove"); items.removeAll { $0.id == id } }
        func allTaskIds() async throws -> Set<String> { Set(items.map(\.taskId)) }
        func all() async throws -> [SyncQueueItem] { items }
    }

    private func makeStore(repo: LoggingRepository, queue: LoggingQueue) throws -> TaskStore {
        let db = try AppDatabase.inMemory()
        return TaskStore(repository: repo,
                         smartViewRepository: GRDBSmartViewRepository(db),
                         archiveRepository: GRDBArchiveRepository(db),
                         defaults: UserDefaults(suiteName: "t.\(UUID().uuidString)")!,
                         clock: { Date(timeIntervalSince1970: 1000) },
                         syncQueue: queue)
    }
    private func task(_ id: String) -> Task {
        Task(id: id, title: id, urgent: false, important: false,
             createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
    }

    @Test func createEnqueuesBeforeUpserting() async throws {
        let log = EventLog()
        let store = try makeStore(repo: LoggingRepository(log: log), queue: LoggingQueue(log: log))
        try await store.create(task("a"))
        #expect(log.events == ["enqueue", "upsert"])
    }

    @Test func deleteEnqueuesBeforeDeleting() async throws {
        let log = EventLog()
        let store = try makeStore(repo: LoggingRepository(log: log), queue: LoggingQueue(log: log))
        try await store.delete(task("a"))
        #expect(log.events == ["enqueue", "delete"])
    }

    @Test func failedUpsertRemovesTheOrphanedQueueItem() async throws {
        let log = EventLog()
        let repo = LoggingRepository(log: log); repo.failUpsert = true
        let queue = LoggingQueue(log: log)
        let store = try makeStore(repo: repo, queue: queue)
        await #expect(throws: LoggingRepository.Boom.self) { try await store.create(self.task("a")) }
        #expect(queue.items.isEmpty)                                  // orphan cleaned up
        #expect(log.events == ["enqueue", "upsert", "remove"])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter TaskStoreWriteOrderTests`
Expected: FAIL — `createEnqueuesBeforeUpserting` sees `["upsert", "enqueue"]` (current order); the cleanup test sees a surviving item.

- [ ] **Step 3: Implement in TaskStore**

In `GSDKit/Sources/GSDStore/TaskStore.swift`, change the private `enqueue` to return the item id, and add the shared race-proof write helper next to it:

```swift
    /// Enqueue a sync op for a local mutation (§7.5). `.delete` carries no payload. Best-effort —
    /// a queue failure must not fail the user's mutation (the next sync's seed/reconcile
    /// self-heals). Returns the queue-item id so a failed companion write can remove the orphan.
    @discardableResult
    private func enqueue(_ taskId: String, _ op: SyncQueueItem.Operation, payload: Task?) async -> String? {
        let item = SyncQueueItem(id: IDGenerator.generate(size: IDGenerator.Size.task),
                                 taskId: taskId, operation: op,
                                 timestamp: Int(clock().timeIntervalSince1970 * 1000),
                                 payload: op == .delete ? nil : payload)
        do { try await syncQueue.enqueue(item) } catch { return nil }
        onMutation?()
        return item.id
    }

    /// Race-proof write (design 2026-06-10 Fix E): persist the queue item BEFORE the task row.
    /// Both serialize through the same GRDB writer, so any task visible to a reconcile
    /// `fetchAll` already has queue protection. If the upsert then fails, the orphaned item is
    /// removed — an unpersisted task must not push a ghost create.
    private func upsertEnqueued(_ task: Task, op: SyncQueueItem.Operation) async throws {
        let queueItemId = await enqueue(task.id, op, payload: task)
        do {
            try await repository.upsert(task)
        } catch {
            if let queueItemId { try? await syncQueue.remove(id: queueItemId) }
            throw error
        }
    }
```

Then swap every mutation path to the new order. Each current `try await repository.upsert(X)` + `await enqueue(X.id, OP, payload: X)` pair becomes one `try await upsertEnqueued(X, op: OP)`:

- `add`: `try await upsertEnqueued(task, op: .create)` (keep the trailing capture-bar comment)
- `create`: `try await upsertEnqueued(t, op: .create)`
- `save`: `try await upsertEnqueued(t, op: .update)`
- `toggleComplete`: main write → `try await upsertEnqueued(t, op: .update)`; recurrence spawn → `try await upsertEnqueued(next, op: .create)`
- `move`, `snooze`, `startTimer`, `stopTimer`, and the private `persist`: `op: .update`
- `restore`: `try await upsertEnqueued(t, op: .update)` (after `archiveRepository.restore`)
- `delete` becomes:

```swift
    public func delete(_ task: Task) async throws {
        let queueItemId = await enqueue(task.id, .delete, payload: nil)
        do {
            try await repository.delete(id: task.id)
        } catch {
            if let queueItemId { try? await syncQueue.remove(id: queueItemId) }
            throw error
        }
        await reminders.cancel(taskID: task.id)
    }
```

- `importTasks` `.replace` mode — enqueue everything first, clean all up if the bulk write fails:

```swift
        case .replace:
            let existingIDs = Set(try await repository.fetchAll().map(\.id))
            let result = try TaskImporter.replace(from: data)
            let importedIDs = Set(result.tasks.map(\.id))
            let now = clock()
            let stamped = result.tasks.map { task -> Task in
                var t = task; t.updatedAt = now; return t
            }
            var enqueued: [String] = []
            for t in stamped {
                if let id = await enqueue(t.id, .update, payload: t) { enqueued.append(id) }
            }
            // §3.4: cleared-but-not-imported tasks must be deleted remotely too (the App drains via
            // SyncCoordinator.flushAfterReplace under the pull-suppression gate).
            for removed in existingIDs.subtracting(importedIDs) {
                if let id = await enqueue(removed, .delete, payload: nil) { enqueued.append(id) }
            }
            do {
                try await repository.replaceAll(stamped)
            } catch {
                for id in enqueued { try? await syncQueue.remove(id: id) }
                throw error
            }
            return result
```

- `importTasks` `.merge` mode loop body: `var t = task; t.updatedAt = clock(); try await upsertEnqueued(t, op: .update)`

- [ ] **Step 4: Swap the read order in `SyncEngine.reconcileDeletions`**

In `GSDKit/Sources/GSDSync/SyncEngine.swift`:

```swift
    /// §7.4 step 5 (destructive — runs LAST, over a FRESH post-push remote index): delete local
    /// ACTIVE tasks absent remotely AND not in the queue. `fetchAll()` is the active table only
    /// (archived is a separate repo, out of scope). `allTaskIds()` = pending + failed (both
    /// protect) and is read AFTER `fetchAll` — TaskStore enqueues before it upserts, so any task
    /// in the snapshot already has its protection visible to this later read (Fix E).
    func reconcileDeletions(token: String) async throws -> Int {
        let remoteIds = Set(try await client.remoteIndex(token: token).keys)
        let snapshot = try await tasks.fetchAll()
        let queuedIds = try await queue.allTaskIds()
        var deleted = 0
        for task in snapshot where !remoteIds.contains(task.id) && !queuedIds.contains(task.id) {
            try await tasks.delete(id: task.id); deleted += 1
        }
        return deleted
    }
```

- [ ] **Step 5: Run the full suite**

Run: `swift test`
Expected: all green (the new ordering tests pass; existing enqueue/reconcile/erase suites prove no behavior broke).

- [ ] **Step 6: Commit**

```bash
git add GSDKit/Sources/GSDStore/TaskStore.swift GSDKit/Sources/GSDSync/SyncEngine.swift GSDKit/Tests/GSDStoreTests/TaskStoreWriteOrderTests.swift
git commit -m "fix(sync): close the reconcile race — enqueue before upsert, queue read after fetch"
```

---

### Task 2: Fix D — bounded observer retry

**Files:**
- Modify: `GSDKit/Sources/GSDStore/TaskStore.swift:86-106` (the three observer starters)
- Create: `GSDKit/Tests/GSDStoreTests/TaskStoreObserverRetryTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
import GSDModel
@testable import GSDStore

/// Fix D: a thrown observation must not freeze the UI for the session — the store retries
/// (bounded) and the stream's next incarnation repopulates the snapshot.
@MainActor
struct TaskStoreObserverRetryTests {
    final class FlakyObserveRepository: TaskRepository, @unchecked Sendable {
        struct Boom: Error {}
        var attempts = 0
        func observeAll() -> AsyncThrowingStream<[Task], Error> {
            attempts += 1
            let attempt = attempts
            return AsyncThrowingStream { cont in
                if attempt == 1 {
                    cont.finish(throwing: Boom())   // first stream dies immediately
                } else {
                    cont.yield([Task(id: "a", title: "back", urgent: false, important: false,
                                     createdAt: Date(timeIntervalSince1970: 0),
                                     updatedAt: Date(timeIntervalSince1970: 0))])
                    // stream stays open like a real observation
                }
            }
        }
        func upsert(_ task: Task) async throws {}
        func fetchAll() async throws -> [Task] { [] }
        func fetch(id: String) async throws -> Task? { nil }
        func delete(id: String) async throws {}
        func replaceAll(_ tasks: [Task]) async throws {}
    }

    @Test func observerRecoversAfterAThrownStream() async throws {
        let db = try AppDatabase.inMemory()
        let repo = FlakyObserveRepository()
        let store = TaskStore(repository: repo,
                              smartViewRepository: GRDBSmartViewRepository(db),
                              archiveRepository: GRDBArchiveRepository(db),
                              defaults: UserDefaults(suiteName: "t.\(UUID().uuidString)")!)
        store.start()
        var waited = 0
        while store.tasks.isEmpty && waited < 300 {                  // retry sleeps 1 s; allow 3 s
            try await _Concurrency.Task.sleep(for: .milliseconds(10)); waited += 1
        }
        #expect(store.tasks.map(\.id) == ["a"])                      // second stream repopulated
        #expect(repo.attempts == 2)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter TaskStoreObserverRetryTests`
Expected: FAIL — `store.tasks` stays empty (current `catch {}` never re-subscribes).

- [ ] **Step 3: Implement the retry loops**

Replace the three starters in `TaskStore`:

```swift
    /// Observation streams retry on error (bounded): a transient I/O failure must not freeze
    /// the UI for the session (Fix D). The failure counter resets on any successful emission;
    /// on final give-up the last good snapshot stays visible. The repository is captured
    /// strongly (an immutable seam); `self` stays weak so deinit-cancellation still works.
    private static let observerMaxConsecutiveFailures = 5

    private func startTaskObserver() {
        guard observerTask == nil else { return }
        let repository = self.repository
        observerTask = _Concurrency.Task { [weak self] in
            var failures = 0
            while !_Concurrency.Task.isCancelled && failures < Self.observerMaxConsecutiveFailures {
                do {
                    for try await snapshot in repository.observeAll() {
                        failures = 0
                        self?.tasks = snapshot
                        self?.onTasksChanged?()
                    }
                    return   // stream ended cleanly (cancellation/termination) — stop
                } catch {
                    failures += 1
                    try? await _Concurrency.Task.sleep(for: .seconds(1))
                }
            }
        }
    }
    private func startSmartViewObserver() {
        guard smartViewObserverTask == nil else { return }
        let repository = self.smartViewRepository
        smartViewObserverTask = _Concurrency.Task { [weak self] in
            var failures = 0
            while !_Concurrency.Task.isCancelled && failures < Self.observerMaxConsecutiveFailures {
                do {
                    for try await snapshot in repository.observeAll() { failures = 0; self?.customViews = snapshot }
                    return
                } catch {
                    failures += 1
                    try? await _Concurrency.Task.sleep(for: .seconds(1))
                }
            }
        }
    }
    private func startArchiveObserver() {
        guard archiveObserverTask == nil else { return }
        let repository = self.archiveRepository
        archiveObserverTask = _Concurrency.Task { [weak self] in
            var failures = 0
            while !_Concurrency.Task.isCancelled && failures < Self.observerMaxConsecutiveFailures {
                do {
                    for try await snapshot in repository.observeAll() { failures = 0; self?.archivedTasks = snapshot }
                    return
                } catch {
                    failures += 1
                    try? await _Concurrency.Task.sleep(for: .seconds(1))
                }
            }
        }
    }
```

- [ ] **Step 4: Run the full suite**

Run: `swift test`
Expected: all green (existing observer-driven tests prove the happy path; the new test proves recovery).

- [ ] **Step 5: Commit**

```bash
git add GSDKit/Sources/GSDStore/TaskStore.swift GSDKit/Tests/GSDStoreTests/TaskStoreObserverRetryTests.swift
git commit -m "fix(store): observers retry after a thrown observation instead of freezing"
```

---

### Task 3: Fix A — `resyncReminders()` + debounced app trigger

**Files:**
- Modify: `GSDKit/Sources/GSDStore/TaskStore.swift` (one new public method, after `refreshBadge`)
- Modify: `GSDKit/Tests/GSDStoreTests/TaskStoreReminderHooksTests.swift`
- Create: `App/Notifications/ReminderResyncer.swift`
- Modify: `App/GSDApp.swift` (wiring)

- [ ] **Step 1: Write the failing test** (append to `TaskStoreReminderHooksTests`)

```swift
    @Test func resyncRemindersRebuildsOnlyEligibleTasks() async throws {
        let rec = RecordingReminderScheduler()
        let store = try makeStore(rec)
        store.start()
        try await store.create(task("due", due: now.addingTimeInterval(3600)))
        try await store.create(task("noDue"))
        try await store.create(task("done", due: now.addingTimeInterval(3600), completed: true))
        var muted = task("muted", due: now.addingTimeInterval(3600))
        muted.notificationEnabled = false
        try await store.create(muted)
        var waited = 0
        while store.tasks.count != 4 && waited < 200 {
            try await _Concurrency.Task.sleep(for: .milliseconds(10)); waited += 1
        }
        rec.calls = []
        await store.resyncReminders()
        #expect(rec.calls.first == .cancelAll)                       // wipe first…
        #expect(rec.scheduleCancelCalls == [.cancelAll, .schedule("due")])  // …then only the eligible task
        #expect(rec.calls.contains { if case .badge = $0 { true } else { false } })  // badge refreshed
    }
```

Note: `scheduleCancelCalls` already filters badge/auth; `.cancelAll` passes its filter. `task(_:due:recurrence:completed:)` is the file's existing helper; the `muted` task is built inline because the helper has no `notificationEnabled` parameter.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter TaskStoreReminderHooksTests`
Expected: FAIL — `resyncReminders` not defined.

- [ ] **Step 3: Implement `resyncReminders` in TaskStore** (after `refreshBadge()`)

```swift
    /// Rebuild reminder + badge state from the live snapshot (design 2026-06-10 Fix A).
    /// Repository-direct writes — sync pull, SSE, deletion-reconcile — never pass through the
    /// §9.1 mutation hooks, so remote changes leave reminders stale on this device. The App
    /// calls this (debounced) whenever the task set changes. Idempotent: `schedule()` uses the
    /// stable `task-<id>` identifier, so re-scheduling replaces rather than duplicates. The
    /// eligibility pre-filter bounds notification-center IPC to reminder-bearing tasks;
    /// `schedule()` keeps final say (quiet hours, past-due → cancel).
    public func resyncReminders() async {
        await reminders.cancelAll()
        for task in tasks where !task.completed && task.dueDate != nil && task.notificationEnabled {
            await reminders.schedule(task)
        }
        await refreshBadge()
    }
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter TaskStoreReminderHooksTests`
Expected: PASS (all, including the pre-existing hook tests).

- [ ] **Step 5: Create the app-layer debouncer** — `App/Notifications/ReminderResyncer.swift`

```swift
import Foundation
import GSDStore

/// Debounced reminder resync — the reminder counterpart of `WidgetSnapshotRefresher`
/// (design 2026-06-10 Fix A). Fired from `TaskStore.onTasksChanged`, so the GRDB observer's
/// initial emission doubles as the launch sweep (no `start()`: sweeping before the first
/// emission would cancelAll against an empty snapshot and briefly wipe live reminders).
@MainActor
final class ReminderResyncer {
    private let store: TaskStore
    private let debounce: Duration
    private var debounceTask: _Concurrency.Task<Void, Never>?

    init(store: TaskStore, debounce: Duration = .seconds(1)) {
        self.store = store
        self.debounce = debounce
    }

    /// Coalesce a burst of task changes (bulk pull/import) into one sweep.
    func schedule() {
        debounceTask?.cancel()
        debounceTask = _Concurrency.Task { [weak self] in
            guard let self else { return }
            try? await _Concurrency.Task.sleep(for: self.debounce)
            if _Concurrency.Task.isCancelled { return }
            await self.store.resyncReminders()
        }
    }
}
```

- [ ] **Step 6: Wire it in `App/GSDApp.swift`**

Add the stored property next to `widgetRefresher`:

```swift
    @State private var reminderResyncer: ReminderResyncer
```

In `init()`, replace the `store.onTasksChanged` line and its surroundings:

```swift
        let widgetRefresher = WidgetSnapshotRefresher(store: store)
        _widgetRefresher = State(initialValue: widgetRefresher)
        // Reminder resync (Fix A): remote writes (pull/SSE/reconcile) bypass the §9.1 mutation
        // hooks; this rebuilds reminders+badge from the snapshot on every observed change.
        let reminderResyncer = ReminderResyncer(store: store)
        _reminderResyncer = State(initialValue: reminderResyncer)
        store.onTasksChanged = {
            widgetRefresher.schedule()
            reminderResyncer.schedule()
        }
```

- [ ] **Step 7: Full suite + both simulator builds**

```bash
swift test
cd .. && xcodegen generate
xcodebuild -project GSD.xcodeproj -scheme GSD -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
xcodebuild -project GSD.xcodeproj -scheme GSD -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' build
```
Expected: tests green, both builds SUCCEED. (xcodegen needed because a new App source file was added — XcodeGen globs `App/`, so regenerate keeps the pbxproj canonical.)

- [ ] **Step 8: Commit**

```bash
git add GSDKit/Sources/GSDStore/TaskStore.swift GSDKit/Tests/GSDStoreTests/TaskStoreReminderHooksTests.swift App/Notifications/ReminderResyncer.swift App/GSDApp.swift GSD.xcodeproj
git commit -m "fix(notifications): resync reminders+badge after sync-driven task changes"
```

---

### Task 4: Fix B — server-stamped pull cursor

**Files:**
- Modify: `GSDKit/Sources/GSDSync/WireDate.swift`
- Modify: `GSDKit/Sources/GSDSync/PocketBaseTaskRecord.swift`
- Modify: `GSDKit/Sources/GSDSync/PocketBaseTaskList.swift`
- Modify: `GSDKit/Sources/GSDSync/SyncCursor.swift`
- Modify: `GSDKit/Sources/GSDSync/SyncEngine.swift` (`pull`, `sync` default `since`, `advance` call)
- Modify: `GSDKit/Tests/GSDSyncTests/WireDateTests.swift`, `SyncCursorTests.swift`, `PocketBaseTaskListTests.swift`, `PocketBaseTaskRecordTests.swift`, `SyncEnginePullTests.swift`
- Modify: `spec.md:534` (§7.1 wording)

- [ ] **Step 1: WireDate — failing tests** (append to `WireDateTests`)

```swift
    @Test func parsesPocketBaseSystemDateSpaceForm() {
        let space = WireDate.parse("2026-06-10 12:00:00.123Z")
        #expect(space != nil)
        #expect(space == WireDate.parse("2026-06-10T12:00:00.123Z"))
    }

    @Test func formatPocketBaseRoundTripsViaSpaceForm() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let s = WireDate.formatPocketBase(date)
        #expect(s.contains(" ") && !s.contains("T"))
        #expect(WireDate.parse(s) == date)
    }
```

Run: `swift test --filter WireDateTests` → FAIL (`formatPocketBase` undefined; space form unparsed).

- [ ] **Step 2: WireDate — implement**

```swift
    /// Empty → nil; fractional-seconds → Date; whole-second → Date; otherwise nil.
    /// PocketBase SYSTEM dates (`updated`/`created`) use a space separator
    /// ("2026-06-10 12:00:00.123Z") — normalized to 'T' before the lenient parse.
    static func parse(_ string: String) -> Date? {
        if string.isEmpty { return nil }
        let normalized = string.replacingOccurrences(of: " ", with: "T")
        if let date = fractional().date(from: normalized) { return date }
        return wholeSecond().date(from: normalized)
    }

    /// PocketBase-native system-date form (space separator) — the `updated` cursor/filter format.
    static func formatPocketBase(_ date: Date) -> String {
        fractional().string(from: date).replacingOccurrences(of: "T", with: " ")
    }
```

Run: `swift test --filter WireDateTests` → PASS.

- [ ] **Step 3: PocketBaseTaskRecord — decode-only `updated`**

Failing test (append to `PocketBaseTaskRecordTests`):

```swift
    @Test func decodesServerUpdatedButNeverEncodesIt() throws {
        let json = #"{"task_id":"a","updated":"2026-06-10 12:00:00.123Z"}"#
        let rec = try JSONDecoder().decode(PocketBaseTaskRecord.self, from: Data(json.utf8))
        #expect(rec.updated == "2026-06-10 12:00:00.123Z")
        let encoded = String(decoding: try JSONEncoder().encode(rec), as: UTF8.self)
        #expect(!encoded.contains("\"updated\""))   // PB owns system fields; never send one
    }
```

Implement: add the stored property after `deviceId` —

```swift
    /// PocketBase's server-stamped `updated` autodate (raw wire string). DECODE-ONLY: it is
    /// deliberately absent from `CodingKeys`, so the synthesized encoder never sends it — PB
    /// owns its system fields. Used solely as the pull cursor (§7.1 cursor exception).
    var updated: String
```

In `init(from:)`, after the main container reads:

```swift
        let system = try decoder.container(keyedBy: SystemKeys.self)
        updated = try system.decodeIfPresent(String.self, forKey: .updated) ?? ""
```

Add below `CodingKeys`:

```swift
    private enum SystemKeys: String, CodingKey { case updated }
```

Memberwise init: add a final defaulted parameter `updated: String = ""` and `self.updated = updated` (existing `TaskWireMapper.toWire` call site compiles unchanged). Update the type doc comment's "System `created`/`updated` are omitted" sentence to: "System `created` is omitted; `updated` is decode-only — it is the pull cursor (§7.1), never a conflict input and never encoded."

Run: `swift test --filter PocketBaseTaskRecordTests` → PASS.

- [ ] **Step 4: listTasks — filter/sort on `updated`**

Failing test (append to `PocketBaseTaskListTests`):

```swift
    @Test func filtersAndSortsOnServerUpdated() async throws {
        let exec = PagingExecutor()
        let client = PocketBaseClient(baseURL: "https://api.vinny.io", executor: exec)
        _ = try await client.listTasks(updatedSince: "2026-06-10 12:00:00.000Z", token: "TOK")
        let url = try #require(exec.requestedPaths.first)
        #expect(url.contains("sort=updated"))
        let decoded = url.removingPercentEncoding ?? url
        #expect(decoded.contains(#"filter=updated >= "2026-06-10 12:00:00.000Z""#))
    }
```

Implement in `PocketBaseTaskList.swift`:

```swift
    /// Pull `tasks` records with server-stamped `updated >= since` (PB space-form date), paging
    /// through ALL pages (data-completeness — never drop page 2+). `updated` is the PULL CURSOR
    /// only (§7.1 cursor exception, design 2026-06-10 Fix B) — LWW still resolves on
    /// `client_updated_at`. Malformed individual records are skipped (§7.4) via `Failable`.
    /// The `owner` API rule auto-scopes to the authed user. (Live gate: confirm the collection
    /// has the autodate `updated` field — owner confirmed 2026-06-10.)
    func listTasks(updatedSince since: String, token: String, perPage: Int = 200) async throws -> [PocketBaseTaskRecord] {
        var all: [PocketBaseTaskRecord] = []
        var page = 1
        while true {
            let filter = "updated >= \"\(since)\""
            let encoded = filter.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? filter
            let path = "/api/collections/tasks/records?page=\(page)&perPage=\(perPage)&sort=updated&filter=\(encoded)"
            let req = authedRequest(path: path, method: "GET", token: token)
            let pg = try await send(req, as: ListPage<Failable<PocketBaseTaskRecord>>.self)
            all.append(contentsOf: pg.items.compactMap(\.value))
            if page >= pg.totalPages { break }
            page += 1
        }
        return all
    }
```

Run: `swift test --filter PocketBaseTaskListTests` → PASS.

- [ ] **Step 5: SyncCursor — new key + legacy migration**

Replace `SyncCursorTests` body (the two clamp tests die with the clamp):

```swift
struct SyncCursorTests {
    private func freshDefaults() -> UserDefaults {
        let suite = "test.synccursor.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!; d.removePersistentDomain(forName: suite); return d
    }

    @Test func unsetCursorIsNil() {
        #expect(SyncCursor(defaults: freshDefaults()).load() == nil)
    }

    @Test func advanceWritesPocketBaseFormMinusFiveSeconds() throws {
        let cursor = SyncCursor(defaults: freshDefaults())
        cursor.advance(maxApplied: Date(timeIntervalSince1970: 1_000_000_000))
        let stored = try #require(cursor.load())
        #expect(stored.contains(" ") && !stored.contains("T"))      // PB space form
        let date = try #require(WireDate.parse(stored))
        #expect(Int(date.timeIntervalSince1970) == 1_000_000_000 - 5)
    }

    @Test func advanceNoOpWhenMaxAppliedNil() {
        let cursor = SyncCursor(defaults: freshDefaults())
        cursor.advance(maxApplied: nil)
        #expect(cursor.load() == nil)
    }

    @Test func legacyClientCursorMigratesWithDayRewind() throws {
        let defaults = freshDefaults()
        defaults.set("2026-06-10T12:00:00.000Z", forKey: "gsd.sync.lastSyncAt")
        let stored = try #require(SyncCursor(defaults: defaults).load())
        let date = try #require(WireDate.parse(stored))
        let expected = try #require(WireDate.parse("2026-06-10T12:00:00.000Z"))
        #expect(date == expected.addingTimeInterval(-24 * 60 * 60))
        #expect(stored.contains(" "))                                // re-emitted in PB form
    }

    @Test func advanceRetiresTheLegacyKey() {
        let defaults = freshDefaults()
        defaults.set("2026-06-10T12:00:00.000Z", forKey: "gsd.sync.lastSyncAt")
        SyncCursor(defaults: defaults).advance(maxApplied: Date(timeIntervalSince1970: 2_000_000_000))
        #expect(defaults.string(forKey: "gsd.sync.lastSyncAt") == nil)
        #expect(SyncCursor(defaults: defaults).load() != nil)
    }

    @Test func clearRemovesBothKeys() {
        let defaults = freshDefaults()
        defaults.set("legacy", forKey: "gsd.sync.lastSyncAt")
        let cursor = SyncCursor(defaults: defaults)
        cursor.advance(maxApplied: Date(timeIntervalSince1970: 1000))
        cursor.clear()
        #expect(cursor.load() == nil)
        #expect(defaults.string(forKey: "gsd.sync.lastSyncAt") == nil)
    }
}
```

Implement `SyncCursor.swift` (doc comment updated for the new semantics):

```swift
/// The pull cursor — the max SERVER-stamped `updated` seen, persisted in PocketBase's space
/// form in App-Group defaults (design 2026-06-10 Fix B: device clocks are irrelevant to pull
/// completeness; LWW still resolves on `client_updated_at`). `nil` ⇒ never synced (triggers
/// the first-sign-in seed). Cleared on sign-out. A legacy CLIENT-time cursor
/// (`gsd.sync.lastSyncAt`) migrates on read with a 24 h rewind (old client stamps are usually
/// near server time; re-pulls are idempotent via the LWW equal-ms no-op) and is retired on the
/// first advance.
// @unchecked Sendable: see prior rationale (thread-safe UserDefaults + immutable keys).
public struct SyncCursor: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "gsd.sync.lastServerUpdated"
    private let legacyKey = "gsd.sync.lastSyncAt"

    public init(defaults: UserDefaults = AppGroupDefaults.shared) { self.defaults = defaults }

    func load() -> String? {
        if let current = defaults.string(forKey: key) { return current }
        guard let legacy = defaults.string(forKey: legacyKey),
              let date = WireDate.parse(legacy) else { return nil }
        return WireDate.formatPocketBase(date.addingTimeInterval(-24 * 60 * 60))
    }

    /// Advance to `maxApplied − 5 s` (server-stamped, so no client-clock clamp; the small
    /// rewind covers same-second write overlap). No-op when `maxApplied` is nil.
    func advance(maxApplied: Date?) {
        guard let maxApplied else { return }
        defaults.set(WireDate.formatPocketBase(maxApplied.addingTimeInterval(-5)), forKey: key)
        defaults.removeObject(forKey: legacyKey)
    }

    func clear() {
        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: legacyKey)
    }
}
```

Run: `swift test --filter SyncCursorTests` → PASS.

- [ ] **Step 6: SyncEngine — maxApplied from `updated`, new default `since`, advance call**

In `pull(token:since:)`, replace the per-record head:

```swift
        for record in records {
            guard let remoteUpdated = WireDate.parse(record.clientUpdatedAt) else { continue }
            // Cursor advances on SERVER stamps (Fix B); LWW below stays on client stamps.
            // Records with an unparseable `updated` apply but don't advance the cursor.
            if let serverUpdated = WireDate.parse(record.updated) {
                maxApplied = max(maxApplied ?? .distantPast, serverUpdated)
            }
```

(The old `maxApplied = max(maxApplied ?? .distantPast, remoteUpdated)` line is removed.)

In `sync(trigger:)`: `let since = cursor.load() ?? "1970-01-01 00:00:00.000Z"` and `cursor.advance(maxApplied: maxApplied)`.

Update `SyncEnginePullTests.wire(_:title:updated:)` so fixtures carry the server field (same value keeps the existing `maxApplied` expectation true):

```swift
    private func wire(_ id: String, title: String, updated: String) -> String {
        #"{"task_id":"\#(id)","title":"\#(title)","urgent":true,"important":false,"client_updated_at":"\#(updated)","client_created_at":"\#(updated)","updated":"\#(updated)"}"#
    }
```

- [ ] **Step 7: spec.md §7.1 wording (line 534)**

Replace the table row:

```
| `created`, `updated` | string (system) | **do not** use for conflict resolution — LWW is `client_updated_at` only. Exception (2026-06-10): `updated` is the iOS pull cursor (filter `updated >= cursor`, sort `updated`) — pull *completeness* may use the server stamp; conflict *decisions* may not |
```

- [ ] **Step 8: Full suite — fix any remaining fixture fallout**

Run: `swift test`
Expected: green. If another suite's inline fixture feeds `pull()` and asserts a cursor/maxApplied value, add `"updated":"<same-as-client_updated_at>"` to that fixture the same way as Step 6.

- [ ] **Step 9: Commit**

```bash
git add GSDKit/Sources/GSDSync GSDKit/Tests/GSDSyncTests spec.md
git commit -m "fix(sync): pull cursor on server-stamped updated — device clock skew can no longer lose pulls"
```

---

### Task 5: Fix C — cross-account sign-in prompt

**Files:**
- Create: `GSDKit/Sources/GSDSync/AccountSwitch.swift`
- Modify: `GSDKit/Sources/GSDSync/AuthService.swift` (add `currentUserId()`)
- Create: `GSDKit/Tests/GSDSyncTests/AccountSwitchTests.swift`
- Modify: `GSDKit/Tests/GSDSyncTests/AuthServiceTests.swift` (currentUserId tests)
- Modify: `App/Auth/SessionStore.swift` (routing + resolution)
- Modify: `App/GSDApp.swift` (closure wiring)
- Modify: `App/ContentView.swift` (confirmation dialog)

- [ ] **Step 1: Failing tests — pure decision + currentUserId**

`GSDKit/Tests/GSDSyncTests/AccountSwitchTests.swift`:

```swift
import Testing
@testable import GSDSync

struct AccountSwitchTests {
    @Test func firstEverSignInProceeds() {
        #expect(AccountSwitch.evaluate(lastOwnerId: nil, newOwnerId: "u1",
                                       hasLocalActiveTasks: true) == .proceed)
    }
    @Test func sameAccountProceeds() {
        #expect(AccountSwitch.evaluate(lastOwnerId: "u1", newOwnerId: "u1",
                                       hasLocalActiveTasks: true) == .proceed)
    }
    @Test func differentAccountWithNoLocalTasksProceeds() {
        #expect(AccountSwitch.evaluate(lastOwnerId: "u1", newOwnerId: "u2",
                                       hasLocalActiveTasks: false) == .proceed)
    }
    @Test func differentAccountWithLocalTasksPrompts() {
        #expect(AccountSwitch.evaluate(lastOwnerId: "u1", newOwnerId: "u2",
                                       hasLocalActiveTasks: true) == .prompt)
    }
}
```

Append to `AuthServiceTests`:

```swift
    @Test func currentUserIdReadsTheStoredTokenWithoutValidation() {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJpZCI6InUxIiwiZXhwIjo5OTk5OTk5OTk5fQ.x"   // id u1
        let service = refreshService(store: InMemoryTokenStore(jwt), exec: FakeExecutor(),
                                     now: Date(timeIntervalSince1970: 0))
        #expect(service.currentUserId() == "u1")
    }
    @Test func currentUserIdNilWhenSignedOut() {
        let service = refreshService(store: InMemoryTokenStore(), exec: FakeExecutor(),
                                     now: Date(timeIntervalSince1970: 0))
        #expect(service.currentUserId() == nil)
    }
```

Run: `swift test --filter "AccountSwitchTests|AuthServiceTests"` → FAIL (types/methods undefined).

- [ ] **Step 2: Implement the GSDSync pieces**

`GSDKit/Sources/GSDSync/AccountSwitch.swift`:

```swift
import Foundation

/// Pure decision for the cross-account guard (design 2026-06-10 Fix C): the §7.4 first-sync
/// seed would silently upload the PREVIOUS account's local tasks into a DIFFERENT account —
/// that needs explicit user consent. `public` — the App's SessionStore routes on it.
public enum AccountSwitch {
    public enum Decision: Equatable, Sendable { case proceed, prompt }

    /// `.prompt` only when a previous owner is known, the new owner differs, and there are
    /// local active tasks to leak. First-ever sign-in (no recorded owner) and same-account
    /// re-auth keep today's behavior. Archived tasks never sync, so they don't gate this.
    public static func evaluate(lastOwnerId: String?, newOwnerId: String,
                                hasLocalActiveTasks: Bool) -> Decision {
        guard let lastOwnerId, lastOwnerId != newOwnerId, hasLocalActiveTasks else { return .proceed }
        return .prompt
    }
}
```

In `AuthService.swift`, after `signOut()`:

```swift
    /// The signed-in PocketBase user id from the STORED token (no validation, no refresh) —
    /// the App's account-switch guard records this as the last-known owner. nil when signed
    /// out or the token is unparseable.
    public func currentUserId() -> String? {
        tokenStore.load().flatMap { JWT.userId($0) }
    }
```

Run: `swift test --filter "AccountSwitchTests|AuthServiceTests"` → PASS.

- [ ] **Step 3: SessionStore routing**

In `App/Auth/SessionStore.swift` — add state, keys, and seams:

```swift
    /// Set when a DIFFERENT account signed in while local tasks exist (design Fix C); the
    /// ContentView dialog resolves it. Sync stays parked until resolved.
    struct PendingAccountSwitch: Equatable {
        let newOwnerId: String
        let newEmail: String?
    }
    private(set) var pendingAccountSwitch: PendingAccountSwitch?

    enum AccountSwitchResolution { case merge, fresh, cancel }
```

New stored properties + init (replaces the current init signature; defaults keep previews/tests compiling):

```swift
    private let lastOwnerKey = "gsd.lastOwnerId"
    private let hasLocalActiveTasks: @MainActor () -> Bool
    private let eraseLocal: @MainActor () async throws -> Void

    init(auth: AuthService, tokenStore: TokenStore, coordinator: SyncCoordinator? = nil,
         hasLocalActiveTasks: @escaping @MainActor () -> Bool = { false },
         eraseLocal: @escaping @MainActor () async throws -> Void = {}) {
        self.auth = auth
        self.tokenStore = tokenStore
        self.coordinator = coordinator
        self.hasLocalActiveTasks = hasLocalActiveTasks
        self.eraseLocal = eraseLocal
        if tokenStore.load() != nil {
            let cached = UserDefaults.standard.string(forKey: emailKey)
            email = cached
            usingRelayEmail = cached.map(AppleIdentity.isRelayEmail) ?? false
            // Backfill the owner baseline for installs that signed in before Fix C shipped —
            // without it, the first account switch after upgrading couldn't be detected.
            if UserDefaults.standard.string(forKey: lastOwnerKey) == nil,
               let id = auth.currentUserId() {
                UserDefaults.standard.set(id, forKey: lastOwnerKey)
            }
        }
    }
```

In BOTH `signIn(provider:)` and `signInWithApple(authorizationCode:)`, replace the
`coordinator?.start(trigger: .signIn)` line (keep each method's email/relay handling as-is) with:

```swift
            routeAfterSignIn(result)
```

Add the routing + resolution methods:

```swift
    /// Same/first account → record owner + start sync (today's behavior). Different account
    /// with local tasks → park sync and let the dialog decide (design Fix C).
    private func routeAfterSignIn(_ result: AuthResult) {
        let last = UserDefaults.standard.string(forKey: lastOwnerKey)
        switch AccountSwitch.evaluate(lastOwnerId: last, newOwnerId: result.record.id,
                                      hasLocalActiveTasks: hasLocalActiveTasks()) {
        case .proceed:
            UserDefaults.standard.set(result.record.id, forKey: lastOwnerKey)
            coordinator?.start(trigger: .signIn)
        case .prompt:
            pendingAccountSwitch = PendingAccountSwitch(newOwnerId: result.record.id,
                                                        newEmail: result.record.email)
        }
    }

    /// Synchronous claim (nil-out) so a button action and the dialog's dismiss binding can
    /// never double-resolve; the async work runs after the claim.
    func resolveAccountSwitch(_ resolution: AccountSwitchResolution) {
        guard let pending = pendingAccountSwitch else { return }
        pendingAccountSwitch = nil
        _Concurrency.Task { await self.apply(resolution, pending: pending) }
    }

    /// Outside-tap dismissal: runs one runloop turn AFTER any button action (which claims
    /// synchronously), so it only fires when the dialog was dismissed without a choice.
    func cancelAccountSwitchIfUnresolved() {
        guard pendingAccountSwitch != nil else { return }
        resolveAccountSwitch(.cancel)
    }

    private func apply(_ resolution: AccountSwitchResolution,
                       pending: PendingAccountSwitch) async {
        switch resolution {
        case .merge:
            UserDefaults.standard.set(pending.newOwnerId, forKey: lastOwnerKey)
            coordinator?.start(trigger: .signIn)
        case .fresh:
            do {
                try await eraseLocal()
            } catch {
                lastError = String(localized: "Couldn't clear this device — signed out instead. Please try again.")
                signOut()
                return
            }
            UserDefaults.standard.set(pending.newOwnerId, forKey: lastOwnerKey)
            coordinator?.start(trigger: .signIn)
        case .cancel:
            signOut()   // no half-signed-in limbo (signed-in UI, parked sync)
        }
    }
```

In `signOut()`, add `pendingAccountSwitch = nil` after `usingRelayEmail = false`. Do **not**
touch `lastOwnerKey` there — remembering the previous owner is the point.

- [ ] **Step 4: GSDApp wiring**

In `App/GSDApp.swift`, replace the `_session = State(...)` line:

```swift
        _session = State(initialValue: SessionStore(
            auth: authService, tokenStore: tokenStore, coordinator: coordinator,
            hasLocalActiveTasks: { !store.tasks.isEmpty },
            eraseLocal: { try await store.eraseAllData() }))
```

- [ ] **Step 5: ContentView dialog**

In `App/ContentView.swift`, add the environment handle below the size-class line:

```swift
    @Environment(SessionStore.self) private var session
```

Chain onto `rootContent` (after `.onOpenURL`):

```swift
            .confirmationDialog(
                String(localized: "Different account"),
                isPresented: Binding(
                    get: { session.pendingAccountSwitch != nil },
                    set: { presented in
                        if !presented {
                            // Defer one turn: a button action claims synchronously first, so
                            // this only cancels a no-choice (outside-tap) dismissal.
                            _Concurrency.Task { @MainActor in session.cancelAccountSwitchIfUnresolved() }
                        }
                    }
                ),
                titleVisibility: .visible
            ) {
                Button(String(localized: "Keep my tasks")) { session.resolveAccountSwitch(.merge) }
                Button(String(localized: "Start fresh (erase tasks on this device)"), role: .destructive) {
                    session.resolveAccountSwitch(.fresh)
                }
                Button(String(localized: "Cancel"), role: .cancel) { session.resolveAccountSwitch(.cancel) }
            } message: {
                Text(String(localized: "You signed in as \(session.pendingAccountSwitch?.newEmail ?? String(localized: "a different account")), but this device has tasks from a previous account. Keep them and sync them to this account, or start fresh?"))
            }
```

- [ ] **Step 6: Full suite + both simulator builds**

```bash
swift test
cd .. && xcodegen generate
xcodebuild -project GSD.xcodeproj -scheme GSD -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
xcodebuild -project GSD.xcodeproj -scheme GSD -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' build
```
Expected: tests green; both builds SUCCEED.

- [ ] **Step 7: Commit**

```bash
git add GSDKit/Sources/GSDSync GSDKit/Tests/GSDSyncTests App/Auth/SessionStore.swift App/GSDApp.swift App/ContentView.swift GSD.xcodeproj
git commit -m "feat(auth): prompt merge-or-fresh when a different account signs in with local tasks"
```

---

### Task 6: Final verification + docs

**Files:**
- Modify: project memory (`gsd-ios-project-state.md` — mark the five deferred issues fixed)

- [ ] **Step 1: Full gates one more time**

```bash
cd GSDKit && swift test
cd .. && xcodebuild -project GSD.xcodeproj -scheme GSD -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
xcodebuild -project GSD.xcodeproj -scheme GSD -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' build
```
Expected: all green.

- [ ] **Step 2: Owner live-gate items (manual, two devices — post-merge)**

1. Fix B: confirm the `tasks` collection's autodate `updated` field exists, then a normal sync pulls (no 400 from the `updated` filter) and a web edit reaches the phone.
2. Fix C: sign out, sign in as a different account with local tasks → dialog appears; verify both Keep (tasks appear in the new account) and Start fresh (device empties, then pulls the new account).
3. Fix A: complete a task on the web while the phone is foregrounded → the phone's pending reminder for it disappears (Settings → Notifications → GSD shows none scheduled for it).

- [ ] **Step 3: Update project memory** — mark deferred issues (a)–(e) as fixed in
`~/.claude/projects/-Users-vinnycarpenter-Projects-gsd-iosapp/memory/gsd-ios-project-state.md`, noting the Fix B live-gate dependency on the PB autodate field.
