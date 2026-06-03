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
