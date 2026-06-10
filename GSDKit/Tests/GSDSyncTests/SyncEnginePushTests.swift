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

    // `sync()` derives `owner` from the JWT (unlike `push(token:owner:)`), so these need a real one.
    private static let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJpZCI6InUxIiwiZXhwIjo5OTk5OTk5OTk5fQ.x"
    private func makeSyncEngine(tasks: GRDBTaskRepository, queue: GRDBSyncQueueRepository,
                                exec: RequestExecuting) -> SyncEngine {
        SyncEngine(client: PocketBaseClient(baseURL: "https://api.vinny.io", executor: exec),
                   tasks: tasks, queue: queue,
                   cursor: SyncCursor(defaults: UserDefaults(suiteName: "t.\(UUID().uuidString)")!),
                   deviceId: "dev-A", tokenProvider: { Self.jwt },
                   now: { Date(timeIntervalSince1970: 2_000_000_000) }, throttleMs: 0)
    }

    @Test func manualSyncRevivesFailedItems() async throws {   // §7.7: "tap Sync Now to retry" must be true
        let db = try AppDatabase.inMemory(); let tasks = GRDBTaskRepository(db); let queue = GRDBSyncQueueRepository(db)
        let t = Task(id: "a", title: "x", urgent: false, important: false,
                     createdAt: Date(timeIntervalSince1970: 5_000_000), updatedAt: Date(timeIntervalSince1970: 5_000_000))
        try await queue.enqueue(SyncQueueItem(id: "q1", taskId: "a", operation: .create, timestamp: 1,
                                              retryCount: 5, payload: t, status: .failed,
                                              lastAttemptAt: 1, failedAt: 1))
        let engine = makeSyncEngine(tasks: tasks, queue: queue, exec: CRUDExecutor())   // remote healthy again
        let result = await engine.sync(trigger: .manual)
        #expect(result.pushed == 1)                  // revived + drained
        #expect(try await queue.all().isEmpty)
    }

    @Test func periodicSyncLeavesFailedItemsTerminal() async throws {   // only an explicit retry revives
        let db = try AppDatabase.inMemory(); let tasks = GRDBTaskRepository(db); let queue = GRDBSyncQueueRepository(db)
        let t = Task(id: "a", title: "x", urgent: false, important: false,
                     createdAt: Date(timeIntervalSince1970: 5_000_000), updatedAt: Date(timeIntervalSince1970: 5_000_000))
        try await queue.enqueue(SyncQueueItem(id: "q1", taskId: "a", operation: .create, timestamp: 1,
                                              retryCount: 5, payload: t, status: .failed,
                                              lastAttemptAt: 1, failedAt: 1))
        let engine = makeSyncEngine(tasks: tasks, queue: queue, exec: CRUDExecutor())
        let result = await engine.sync(trigger: .periodic)
        #expect(result.pushed == 0)
        let all = try await queue.all()
        #expect(all.count == 1 && all[0].status == .failed)
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
