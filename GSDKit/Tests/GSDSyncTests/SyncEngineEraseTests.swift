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

    @Test func eraseAllRemoteTokenFailureIsAnErrorNotSignedOut() async throws {
        // A session EXISTS but can't be validated (expired + refresh unavailable). Reporting
        // notSignedIn here would let the caller wipe local while every task survives remotely.
        let db = try AppDatabase.inMemory()
        let eng = SyncEngine(client: PocketBaseClient(baseURL: "https://api.vinny.io", executor: DeleteExecutor()),
                             tasks: GRDBTaskRepository(db), queue: GRDBSyncQueueRepository(db),
                             cursor: SyncCursor(defaults: UserDefaults(suiteName: "t.\(UUID().uuidString)")!),
                             deviceId: "dev-A",
                             tokenProvider: { throw PocketBaseError.network("offline during refresh") },
                             now: { Date(timeIntervalSince1970: 2_000_000_000) }, throttleMs: 0,
                             history: GRDBSyncHistoryRepository(db))
        let result = await eng.eraseAllRemote()
        #expect(!result.notSignedIn)
        #expect(result.error != nil)
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
