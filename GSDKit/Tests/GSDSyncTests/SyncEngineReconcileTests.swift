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
        let survivingD = try await tasks.fetch(id: "d")
        let survivingA = try await tasks.fetch(id: "a")
        let survivingC = try await tasks.fetch(id: "c")          // hoisted: two `await`s in one #expect && trips the autoclosure
        #expect(survivingD == nil)
        #expect(survivingA != nil && survivingC != nil)
    }

    @Test func seedScenarioDeletesNothing() async throws {     // first-sync seed protects everything
        let db = try AppDatabase.inMemory(); let tasks = GRDBTaskRepository(db); let queue = GRDBSyncQueueRepository(db)
        for id in ["a", "b"] { try await tasks.upsert(task(id)); try await queue.enqueue(SyncQueueItem(id: "q-\(id)", taskId: id, operation: .update, timestamp: 1, payload: task(id))) }
        let deleted = try await engine(tasks: tasks, queue: queue, exec: IndexExecutor()).reconcileDeletions(token: "TOK")  // empty remote
        #expect(deleted == 0)                                   // all queued → none deleted
    }
}
