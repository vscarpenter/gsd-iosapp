import Testing
import Foundation
@testable import GSDSync
import GSDStore
import GSDModel

struct SyncEngineHistoryTests {
    final class EmptyExecutor: RequestExecuting, @unchecked Sendable {
        func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            (Data(#"{"page":1,"perPage":200,"totalItems":0,"totalPages":1,"items":[]}"#.utf8),
             HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }
    // header {"alg":"HS256"} . payload {"id":"u1","exp":9999999999} . sig
    let token = "eyJhbGciOiJIUzI1NiJ9.eyJpZCI6InUxIiwiZXhwIjo5OTk5OTk5OTk5fQ.x"

    @Test func syncWritesOneSuccessEntry() async throws {
        let db = try AppDatabase.inMemory()
        let tasks = GRDBTaskRepository(db); let queue = GRDBSyncQueueRepository(db)
        let history = GRDBSyncHistoryRepository(db)
        let suite = UserDefaults(suiteName: "t.\(UUID().uuidString)")!
        let engine = SyncEngine(
            client: PocketBaseClient(baseURL: "https://api.vinny.io", executor: EmptyExecutor()),
            tasks: tasks, queue: queue, cursor: SyncCursor(defaults: suite), deviceId: "dev-A",
            tokenProvider: { self.token }, now: { Date(timeIntervalSince1970: 2_000_000_000) },
            throttleMs: 0, history: history)
        _ = await engine.sync(trigger: .manual)
        let recent = try await history.recent(limit: 10)
        #expect(recent.count == 1)
        #expect(recent[0].status == .success)
        #expect(recent[0].triggeredBy == .user)        // .manual → user
        #expect(recent[0].deviceId == "dev-A")
    }

    @Test func notSignedInWritesNoEntry() async throws {
        let db = try AppDatabase.inMemory()
        let history = GRDBSyncHistoryRepository(db)
        let suite = UserDefaults(suiteName: "t.\(UUID().uuidString)")!
        let engine = SyncEngine(
            client: PocketBaseClient(baseURL: "https://api.vinny.io", executor: EmptyExecutor()),
            tasks: GRDBTaskRepository(db), queue: GRDBSyncQueueRepository(db),
            cursor: SyncCursor(defaults: suite), deviceId: "dev-A",
            tokenProvider: { nil }, now: { Date(timeIntervalSince1970: 2_000_000_000) },
            throttleMs: 0, history: history)
        _ = await engine.sync(trigger: .launch)
        #expect(try await history.recent(limit: 10).isEmpty)   // no attempt → no record
    }
}
