import Testing
import Foundation
@testable import GSDSync
import GSDStore
import GSDModel

/// Regression tests for the Phase 5d code-review findings (data-loss / resurrection paths).
struct SyncEngineReviewFixTests {
    let token = "eyJhbGciOiJIUzI1NiJ9.eyJpZCI6InUxIiwiZXhwIjo5OTk5OTk5OTk5fQ.x"

    private func engine(_ db: AppDatabase, _ exec: RequestExecuting, deviceId: String = "dev-A") -> SyncEngine {
        SyncEngine(client: PocketBaseClient(baseURL: "https://api.vinny.io", executor: exec),
                   tasks: GRDBTaskRepository(db), queue: GRDBSyncQueueRepository(db),
                   cursor: SyncCursor(defaults: UserDefaults(suiteName: "t.\(UUID().uuidString)")!),
                   deviceId: deviceId, tokenProvider: { self.token },
                   now: { Date(timeIntervalSince1970: 2_000_000_000) }, throttleMs: 0,
                   history: GRDBSyncHistoryRepository(db))
    }
    private func sample(_ id: String) -> Task {
        Task(id: id, title: id, urgent: false, important: false,
             createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1))
    }

    // Fix C: a same-drain .create-then-.delete for one task must DELETE the just-created record
    // (the in-memory index is updated after create), not leak an orphan.
    final class CreateDeleteExecutor: RequestExecuting, @unchecked Sendable {
        private(set) var writes: [(method: String, path: String)] = []
        func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let m = request.httpMethod ?? "GET"
            if m == "GET" {   // empty remote index
                return (Data(#"{"page":1,"perPage":200,"totalItems":0,"totalPages":1,"items":[]}"#.utf8),
                        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            writes.append((m, request.url!.path))
            return (Data(#"{"id":"recNEW","task_id":"x","title":"t","urgent":false,"important":false}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: m == "DELETE" ? 204 : 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    @Test func sameDrainCreateThenDeleteDoesNotOrphan() async throws {
        let db = try AppDatabase.inMemory(); let queue = GRDBSyncQueueRepository(db); let exec = CreateDeleteExecutor()
        try await queue.enqueue(SyncQueueItem(id: "c", taskId: "x", operation: .create, timestamp: 1, payload: sample("x")))
        try await queue.enqueue(SyncQueueItem(id: "d", taskId: "x", operation: .delete, timestamp: 2))
        let eng = SyncEngine(client: PocketBaseClient(baseURL: "https://api.vinny.io", executor: exec),
                             tasks: GRDBTaskRepository(db), queue: queue,
                             cursor: SyncCursor(defaults: UserDefaults(suiteName: "t.\(UUID().uuidString)")!),
                             deviceId: "dev-A", tokenProvider: { self.token },
                             now: { Date(timeIntervalSince1970: 2_000_000_000) }, throttleMs: 0,
                             history: GRDBSyncHistoryRepository(db))
        _ = try await eng.push(token: token, owner: "u1")
        #expect(exec.writes.contains { $0.method == "POST" })
        #expect(exec.writes.contains { $0.method == "DELETE" && $0.path.contains("recNEW") })  // not orphaned
        #expect(try await queue.pending().isEmpty)
    }

    // Fix D: a realtime create/update for a task the user just deleted locally (pending .delete) must
    // NOT resurrect it.
    final class EmptyExecutor: RequestExecuting, @unchecked Sendable {
        func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            (Data(#"{"page":1,"perPage":200,"totalItems":0,"totalPages":1,"items":[]}"#.utf8),
             HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    @Test func realtimeUpdateDoesNotResurrectLocallyDeletedTask() async throws {
        let db = try AppDatabase.inMemory()
        let tasks = GRDBTaskRepository(db); let queue = GRDBSyncQueueRepository(db)
        // user deleted t1 locally: row gone, .delete queued (not yet pushed)
        try await queue.enqueue(SyncQueueItem(id: "d1", taskId: "t1", operation: .delete, timestamp: 1))
        let eng = SyncEngine(client: PocketBaseClient(baseURL: "https://api.vinny.io", executor: EmptyExecutor()),
                             tasks: tasks, queue: queue,
                             cursor: SyncCursor(defaults: UserDefaults(suiteName: "t.\(UUID().uuidString)")!),
                             deviceId: "dev-A", tokenProvider: { self.token },
                             now: { Date(timeIntervalSince1970: 2_000_000_000) }, throttleMs: 0,
                             history: GRDBSyncHistoryRepository(db))
        let json = #"{"action":"update","record":{"task_id":"t1","owner":"u1","title":"resurrected?","client_updated_at":"2033-05-18T03:33:20.000Z","device_id":"dev-B"}}"#
        await eng.applyRealtime(rawData: json)
        #expect(try await tasks.fetch(id: "t1") == nil)   // stayed deleted
    }

    // Fix E: a realtime DELETE whose record carries OUR device_id (we were the last writer; another
    // device deleted it) must still apply — deletes are not echo-filtered.
    @Test func realtimeDeleteWithOwnDeviceIdStillApplies() async throws {
        let db = try AppDatabase.inMemory(); let tasks = GRDBTaskRepository(db)
        try await tasks.upsert(sample("t1"))
        let eng = engine(db, EmptyExecutor(), deviceId: "dev-A")
        let json = #"{"action":"delete","record":{"task_id":"t1","owner":"u1","device_id":"dev-A"}}"#
        await eng.applyRealtime(rawData: json)
        #expect(try await tasks.fetch(id: "t1") == nil)   // deleted despite our own device_id on the record
    }

    // Fix A: eraseAllRemote deletes EVERY remote record from a fresh index (even ones not local) and
    // clears the local queue so no stale op resurrects a task.
    final class TwoRecordExecutor: RequestExecuting, @unchecked Sendable {
        private(set) var deletes: [String] = []
        func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            if (request.httpMethod ?? "GET") == "GET" {
                let json = #"{"page":1,"perPage":200,"totalItems":2,"totalPages":1,"items":[{"id":"recA","task_id":"a","client_updated_at":"2001-01-01T00:00:00.000Z"},{"id":"recB","task_id":"b","client_updated_at":"2001-01-01T00:00:00.000Z"}]}"#
                return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            deletes.append(request.url!.lastPathComponent)
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
        }
    }

    @Test func eraseAllRemoteDeletesAllIndexRecordsAndClearsQueue() async throws {
        let db = try AppDatabase.inMemory(); let queue = GRDBSyncQueueRepository(db); let exec = TwoRecordExecutor()
        // a stale pending update that must NOT survive the wipe (else it recreates a task)
        try await queue.enqueue(SyncQueueItem(id: "u1", taskId: "a", operation: .update, timestamp: 1, payload: sample("a")))
        let eng = SyncEngine(client: PocketBaseClient(baseURL: "https://api.vinny.io", executor: exec),
                             tasks: GRDBTaskRepository(db), queue: queue,
                             cursor: SyncCursor(defaults: UserDefaults(suiteName: "t.\(UUID().uuidString)")!),
                             deviceId: "dev-A", tokenProvider: { self.token },
                             now: { Date(timeIntervalSince1970: 2_000_000_000) }, throttleMs: 0,
                             history: GRDBSyncHistoryRepository(db))
        let result = await eng.eraseAllRemote()
        #expect(result.pushed == 2)
        #expect(Set(exec.deletes) == ["recA", "recB"])
        #expect(try await queue.all().isEmpty)   // stale ops cleared
    }
}
