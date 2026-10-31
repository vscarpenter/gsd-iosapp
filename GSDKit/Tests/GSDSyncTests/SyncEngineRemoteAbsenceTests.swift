import Testing
import Foundation
import GSDModel
import GSDStore
@testable import GSDSync
@testable import GSDWire

/// B-07. Three verdicts for a local task the server no longer lists, as on the web
/// (`classifyRemoteDeletion`) and Android (`reconcileDeletions`): a pending row protects it, only
/// failed rows move it to Trash, and no rows delete it locally.
struct SyncEngineRemoteAbsenceTests {
    final class Executor: RequestExecuting, @unchecked Sendable {
        var listJSON = #"{"page":1,"perPage":200,"totalItems":0,"totalPages":1,"items":[]}"#
        var identityStatus = 200
        var identityId = "u1"
        var identityOffline = false
        var writeStatus = 200
        private(set) var identityChecks = 0
        private(set) var writes: [String] = []
        func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let method = request.httpMethod ?? "GET"
            func response(_ body: String, _ status: Int = 200) -> (Data, HTTPURLResponse) {
                (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
            if request.url!.path.hasSuffix("/auth-refresh") {
                identityChecks += 1
                if identityOffline { throw URLError(.notConnectedToInternet) }
                let body = identityStatus == 200 ? #"{"token":"fresh","record":{"id":"\#(identityId)","email":"e@x"}}"# : #"{"message":"nope"}"#
                return response(body, identityStatus)
            }
            if method == "GET" { return response(listJSON) }
            writes.append(method)
            return response(#"{"id":"rec_a","task_id":"a","title":"t","urgent":false,"important":false}"#, writeStatus)
        }
    }

    // token with id "u1"
    private static let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJpZCI6InUxIiwiZXhwIjo5OTk5OTk5OTk5fQ.x"
    private static let now = Date(timeIntervalSince1970: 2_000_000_000)

    final class RecordingReminders: ReminderScheduling, @unchecked Sendable {
        private(set) var cancelled: [String] = []
        func schedule(_ task: Task) async {}
        func cancel(taskID: String) async { cancelled.append(taskID) }
        func cancelAll() async {}
        func requestAuthorizationIfNeeded() async -> Bool { true }
        func setBadge(_ count: Int) async {}
    }

    private func engine(_ db: AppDatabase, _ exec: Executor = Executor(),
                        reminders: any ReminderScheduling = NoopReminderScheduler()) -> SyncEngine {
        let defaults = UserDefaults(suiteName: "t.\(UUID().uuidString)")!
        let cursor = SyncCursor(defaults: defaults)
        cursor.advance(maxApplied: Date(timeIntervalSince1970: 1_000))   // not a first sync, so no seed
        return SyncEngine(client: PocketBaseClient(baseURL: "https://api.vinny.io", executor: exec),
                          tasks: GRDBTaskRepository(db), queue: GRDBSyncQueueRepository(db),
                          tombstones: GRDBTombstoneRepository(db), cursor: cursor,
                          deviceId: "dev-A", tokenProvider: { Self.jwt }, rawToken: { Self.jwt },
                          now: { Self.now }, throttleMs: 0, reminders: reminders)
    }
    private func task(_ id: String = "a") -> Task {
        Task(id: id, title: id, urgent: false, important: false,
             createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1))
    }
    private func failedRow(_ id: String = "f1", taskId: String = "a") -> SyncQueueItem {
        SyncQueueItem(id: id, taskId: taskId, operation: .create, timestamp: 1, retryCount: 5,
                      payload: task(taskId), status: .failed, lastAttemptAt: 1, failedAt: 1)
    }
    private func pendingRow(_ id: String = "p1", taskId: String = "a") -> SyncQueueItem {
        SyncQueueItem(id: id, taskId: taskId, operation: .update, timestamp: 2, payload: task(taskId))
    }

    @Test func aPendingRowProtectsTheTask() async throws {
        let db = try AppDatabase.inMemory(); let tasks = GRDBTaskRepository(db); let queue = GRDBSyncQueueRepository(db)
        try await tasks.upsert(task())
        try await queue.enqueue(pendingRow())
        let deleted = try await engine(db).reconcileDeletions(token: Self.jwt, owner: "u1")
        #expect(deleted == 0)
        #expect(try await tasks.fetch(id: "a") != nil)
        #expect(try await queue.all().count == 1)
    }

    // Pending wins first: a fresh retryable row outranks a stale exhausted one (web `queue.ts`).
    @Test func aPendingRowOutranksAFailedRow() async throws {
        let db = try AppDatabase.inMemory(); let tasks = GRDBTaskRepository(db); let queue = GRDBSyncQueueRepository(db)
        try await tasks.upsert(task())
        try await queue.enqueue(failedRow())
        try await queue.enqueue(pendingRow())
        let deleted = try await engine(db).reconcileDeletions(token: Self.jwt, owner: "u1")
        #expect(deleted == 0)
        #expect(try await tasks.fetch(id: "a") != nil)
        #expect(try await GRDBTrashRepository(db).fetchAll().isEmpty)
        #expect(try await queue.all().count == 2)
    }

    @Test func onlyFailedRowsMoveTheTaskToTrash() async throws {
        let db = try AppDatabase.inMemory(); let tasks = GRDBTaskRepository(db); let queue = GRDBSyncQueueRepository(db)
        try await tasks.upsert(task())
        try await queue.enqueue(failedRow())
        let exec = Executor()
        let deleted = try await engine(db, exec).reconcileDeletions(token: Self.jwt, owner: "u1")
        #expect(deleted == 1)
        #expect(try await tasks.fetch(id: "a") == nil)
        let trashed = try await GRDBTrashRepository(db).fetchAllStamped()
        #expect(trashed.map(\.task.id) == ["a"])
        #expect(trashed.first?.stampedAt == Self.now)
        #expect(try await queue.all().isEmpty)
        #expect(exec.writes.isEmpty)   // the content never reached the server, so nothing to delete there
    }

    @Test func noRowsDeleteTheTaskWithoutATrashCopy() async throws {
        let db = try AppDatabase.inMemory(); let tasks = GRDBTaskRepository(db)
        try await tasks.upsert(task())
        let deleted = try await engine(db).reconcileDeletions(token: Self.jwt, owner: "u1")
        #expect(deleted == 1)
        #expect(try await tasks.fetch(id: "a") == nil)
        #expect(try await GRDBTrashRepository(db).fetchAll().isEmpty)
    }

    @Test func aFailedRowOnATaskTheServerStillListsChangesNothing() async throws {
        let db = try AppDatabase.inMemory(); let tasks = GRDBTaskRepository(db); let queue = GRDBSyncQueueRepository(db)
        try await tasks.upsert(task())
        try await queue.enqueue(failedRow())
        let exec = Executor()
        exec.listJSON = #"{"page":1,"perPage":200,"totalItems":1,"totalPages":1,"items":[{"id":"rec_a","task_id":"a"}]}"#
        let deleted = try await engine(db, exec).reconcileDeletions(token: Self.jwt, owner: "u1")
        #expect(deleted == 0)
        #expect(try await tasks.fetch(id: "a") != nil)
        #expect(try await queue.all().count == 1)
    }

    // The verdict depends on the trigger: `sync()` revives failed rows on a user-facing trigger first.
    @Test func aPeriodicSyncMovesAFailedOnlyTaskToTrash() async throws {
        let db = try AppDatabase.inMemory(); let tasks = GRDBTaskRepository(db); let queue = GRDBSyncQueueRepository(db)
        try await tasks.upsert(task())
        try await queue.enqueue(failedRow())
        let result = await engine(db).sync(trigger: .periodic)
        #expect(result.error == nil && result.deleted == 1)
        #expect(try await GRDBTrashRepository(db).fetchAll().map(\.id) == ["a"])
    }

    @Test func aManualSyncRetriesAFailedOnlyTaskInstead() async throws {
        let db = try AppDatabase.inMemory(); let tasks = GRDBTaskRepository(db); let queue = GRDBSyncQueueRepository(db)
        try await tasks.upsert(task())
        try await queue.enqueue(failedRow())
        let exec = Executor()
        let result = await engine(db, exec).sync(trigger: .manual)
        #expect(result.pushed == 1)
        #expect(exec.writes == ["POST"])
        #expect(try await GRDBTrashRepository(db).fetchAll().isEmpty)
    }

    // MARK: Read order

    /// A task the user creates while reconcile reads the task table. It enqueues first and writes the
    /// row second, as `TaskStore` does, so a queue read AFTER this sees the row that protects the task.
    final class CreatingTasks: TaskRepository, @unchecked Sendable {
        let base: GRDBTaskRepository; let queue: GRDBSyncQueueRepository; let created: Task
        private var done = false
        init(_ base: GRDBTaskRepository, _ queue: GRDBSyncQueueRepository, creating created: Task) {
            self.base = base; self.queue = queue; self.created = created
        }
        func fetchAll() async throws -> [Task] {
            if !done {
                done = true
                try await queue.enqueue(SyncQueueItem(id: "new", taskId: created.id, operation: .create, timestamp: 1, payload: created))
                try await base.upsert(created)
            }
            return try await base.fetchAll()
        }
        func upsert(_ task: Task) async throws { try await base.upsert(task) }
        func fetch(id: String) async throws -> Task? { try await base.fetch(id: id) }
        func delete(id: String) async throws { try await base.delete(id: id) }
        func replaceAll(_ tasks: [Task]) async throws { try await base.replaceAll(tasks) }
        func observeAll() -> AsyncThrowingStream<[Task], Error> { base.observeAll() }
    }

    // Reading the queue first would miss the new row and delete the task with no Trash copy. Android
    // had this bug (AND-RO). The order holds only because the tasks are read before the queue.
    @Test func aTaskCreatedDuringReconcilesTaskReadSurvives() async throws {
        let db = try AppDatabase.inMemory(); let queue = GRDBSyncQueueRepository(db); let base = GRDBTaskRepository(db)
        let tasks = CreatingTasks(base, queue, creating: task("new-task"))
        let cursor = SyncCursor(defaults: UserDefaults(suiteName: "t.\(UUID().uuidString)")!)
        let eng = SyncEngine(client: PocketBaseClient(baseURL: "https://api.vinny.io", executor: Executor()),
                             tasks: tasks, queue: queue, tombstones: GRDBTombstoneRepository(db), cursor: cursor,
                             deviceId: "dev-A", tokenProvider: { Self.jwt }, rawToken: { Self.jwt }, now: { Self.now }, throttleMs: 0)
        let deleted = try await eng.reconcileDeletions(token: Self.jwt, owner: "u1")
        #expect(deleted == 0)
        #expect(try await base.fetch(id: "new-task") != nil)
        #expect(try await queue.all().map(\.id) == ["new"])
    }

    // The fifth failure goes to Trash in the same run, because reconcile runs right after push. On a
    // periodic run nothing revives it first, so the user gets no window. It's owner decision item 10.
    @Test func aFifthFailedPushMovesTheTaskToTrashInTheSameRun() async throws {
        let db = try AppDatabase.inMemory(); let tasks = GRDBTaskRepository(db); let queue = GRDBSyncQueueRepository(db)
        try await tasks.upsert(task())
        try await queue.enqueue(SyncQueueItem(id: "q1", taskId: "a", operation: .create, timestamp: 1, retryCount: 4, payload: task()))
        let exec = Executor(); exec.writeStatus = 400
        let result = await engine(db, exec).sync(trigger: .periodic)
        #expect(result.failed == 1 && result.deleted == 1)
        #expect(try await GRDBTrashRepository(db).fetchAll().map(\.id) == ["a"])
        #expect(try await queue.all().isEmpty)
    }

    // MARK: Reminders

    // A background refresh can end before the app's debounced reminder resync runs, and the OS fires
    // a pending reminder with the app suspended, so reconcile cancels as it removes the task.
    @Test func abandoningATaskCancelsItsReminder() async throws {
        let db = try AppDatabase.inMemory(); let reminders = RecordingReminders()
        try await GRDBTaskRepository(db).upsert(task())
        try await GRDBSyncQueueRepository(db).enqueue(failedRow())
        _ = try await engine(db, reminders: reminders).reconcileDeletions(token: Self.jwt, owner: "u1")
        #expect(reminders.cancelled == ["a"])
    }

    @Test func aRemoteDeleteCancelsTheReminder() async throws {
        let db = try AppDatabase.inMemory(); let reminders = RecordingReminders()
        try await GRDBTaskRepository(db).upsert(task())
        _ = try await engine(db, reminders: reminders).reconcileDeletions(token: Self.jwt, owner: "u1")
        #expect(reminders.cancelled == ["a"])
    }

    @Test func aBackgroundSyncCancelsTheReminderBeforeItReturns() async throws {
        let db = try AppDatabase.inMemory(); let reminders = RecordingReminders()
        try await GRDBTaskRepository(db).upsert(task())
        try await GRDBSyncQueueRepository(db).enqueue(failedRow())
        let result = await engine(db, reminders: reminders).sync(trigger: .background)
        #expect(result.deleted == 1)
        #expect(reminders.cancelled == ["a"])
    }

    @Test func aProtectedTaskKeepsItsReminder() async throws {
        let db = try AppDatabase.inMemory(); let reminders = RecordingReminders()
        try await GRDBTaskRepository(db).upsert(task())
        try await GRDBSyncQueueRepository(db).enqueue(pendingRow())
        _ = try await engine(db, reminders: reminders).reconcileDeletions(token: Self.jwt, owner: "u1")
        #expect(reminders.cancelled.isEmpty)
    }

    @Test func aRejectedSessionKeepsEveryReminder() async throws {
        let db = try AppDatabase.inMemory(); let reminders = RecordingReminders()
        try await seedOneOfEachDestructiveVerdict(db)
        let exec = Executor(); exec.identityStatus = 401
        await #expect(throws: (any Error).self) {
            _ = try await engine(db, exec, reminders: reminders).reconcileDeletions(token: Self.jwt, owner: "u1")
        }
        #expect(reminders.cancelled.isEmpty)
    }

    // MARK: Identity (Android `confirmIdentity`)

    // A request the server treats as a guest lists zero items, so an empty listing proves nothing
    // until the server confirms the session. Both destructive verdicts wait for that.
    private func seedOneOfEachDestructiveVerdict(_ db: AppDatabase) async throws {
        try await GRDBTaskRepository(db).upsert(task("no-rows"))
        try await GRDBTaskRepository(db).upsert(task("failed-only"))
        try await GRDBSyncQueueRepository(db).enqueue(failedRow(taskId: "failed-only"))
    }
    private func expectNothingMoved(_ db: AppDatabase) async throws {
        #expect(try await GRDBTaskRepository(db).fetchAll().count == 2)
        #expect(try await GRDBTrashRepository(db).fetchAll().isEmpty)
        #expect(try await GRDBSyncQueueRepository(db).all().count == 1)
    }

    // Rejected, forbidden, rate limited, and server error: none of them confirm the session.
    @Test(arguments: [401, 403, 429, 500, 503])
    func aFailedIdentityCheckChangesNothing(status: Int) async throws {
        let db = try AppDatabase.inMemory()
        try await seedOneOfEachDestructiveVerdict(db)
        let exec = Executor(); exec.identityStatus = status
        await #expect(throws: (any Error).self) {
            _ = try await engine(db, exec).reconcileDeletions(token: Self.jwt, owner: "u1")
        }
        try await expectNothingMoved(db)
    }

    @Test func anIdentityCheckThatCantReachTheServerChangesNothing() async throws {
        let db = try AppDatabase.inMemory()
        try await seedOneOfEachDestructiveVerdict(db)
        let exec = Executor(); exec.identityOffline = true
        await #expect(throws: (any Error).self) {
            _ = try await engine(db, exec).reconcileDeletions(token: Self.jwt, owner: "u1")
        }
        try await expectNothingMoved(db)
    }

    @Test func aSessionForAnotherAccountChangesNothing() async throws {
        let db = try AppDatabase.inMemory()
        try await seedOneOfEachDestructiveVerdict(db)
        let exec = Executor(); exec.identityId = "someone-else"
        await #expect(throws: SyncIdentityMismatch.self) {
            _ = try await engine(db, exec).reconcileDeletions(token: Self.jwt, owner: "u1")
        }
        try await expectNothingMoved(db)
    }

    @Test func aRejectedSessionSurfacesAsASyncError() async throws {
        let db = try AppDatabase.inMemory()
        try await seedOneOfEachDestructiveVerdict(db)
        let exec = Executor(); exec.identityStatus = 401
        let result = await engine(db, exec).sync(trigger: .periodic)
        #expect(result.error != nil && result.deleted == 0)
        try await expectNothingMoved(db)
    }

    @Test func aConfirmedSessionWithAnEmptyRemoteStillApplies() async throws {
        let db = try AppDatabase.inMemory()
        try await seedOneOfEachDestructiveVerdict(db)
        let exec = Executor()
        let deleted = try await engine(db, exec).reconcileDeletions(token: Self.jwt, owner: "u1")
        #expect(deleted == 2)
        #expect(exec.identityChecks == 1)   // once per run, not once per task
    }

    @Test func aRunWithNothingToReconcileMakesNoIdentityRequest() async throws {
        let db = try AppDatabase.inMemory(); let queue = GRDBSyncQueueRepository(db)
        try await GRDBTaskRepository(db).upsert(task())
        try await queue.enqueue(pendingRow())
        let exec = Executor(); exec.identityStatus = 401
        let deleted = try await engine(db, exec).reconcileDeletions(token: Self.jwt, owner: "u1")
        #expect(deleted == 0)
        #expect(exec.identityChecks == 0)
    }
}
