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
