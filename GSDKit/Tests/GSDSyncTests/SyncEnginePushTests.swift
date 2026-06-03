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
