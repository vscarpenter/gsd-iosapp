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
        private(set) var writes: [String] = []
        func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let method = request.httpMethod ?? "GET"
            if method != "GET" { writes.append(method) }
            let body = method == "GET" ? listJSON : #"{"id":"rec_a","task_id":"a","title":"t","urgent":false,"important":false}"#
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    // token with id "u1"
    private static let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJpZCI6InUxIiwiZXhwIjo5OTk5OTk5OTk5fQ.x"
    private static let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func engine(_ db: AppDatabase, _ exec: Executor = Executor()) -> SyncEngine {
        let defaults = UserDefaults(suiteName: "t.\(UUID().uuidString)")!
        let cursor = SyncCursor(defaults: defaults)
        cursor.advance(maxApplied: Date(timeIntervalSince1970: 1_000))   // not a first sync, so no seed
        return SyncEngine(client: PocketBaseClient(baseURL: "https://api.vinny.io", executor: exec),
                          tasks: GRDBTaskRepository(db), queue: GRDBSyncQueueRepository(db),
                          tombstones: GRDBTombstoneRepository(db), cursor: cursor,
                          deviceId: "dev-A", tokenProvider: { Self.jwt },
                          now: { Self.now }, throttleMs: 0)
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
        let deleted = try await engine(db).reconcileDeletions(token: Self.jwt)
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
        let deleted = try await engine(db).reconcileDeletions(token: Self.jwt)
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
        let deleted = try await engine(db, exec).reconcileDeletions(token: Self.jwt)
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
        let deleted = try await engine(db).reconcileDeletions(token: Self.jwt)
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
        let deleted = try await engine(db, exec).reconcileDeletions(token: Self.jwt)
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
}
