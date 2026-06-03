import Testing
import Foundation
import GSDModel
import GSDStore
@testable import GSDSync

struct SyncEnginePullTests {
    final class ListExecutor: RequestExecuting, @unchecked Sendable {
        var json = #"{"page":1,"perPage":200,"totalItems":0,"totalPages":1,"items":[]}"#
        func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }
    private func engine(_ exec: ListExecutor, _ repo: GRDBTaskRepository) -> SyncEngine {
        SyncEngine(
            client: PocketBaseClient(baseURL: "https://api.vinny.io", executor: exec),
            tasks: repo,
            queue: GRDBSyncQueueRepository(try! AppDatabase.inMemory()),   // unused in pull
            cursor: SyncCursor(defaults: UserDefaults(suiteName: "t.\(UUID().uuidString)")!),
            deviceId: "dev-A",
            tokenProvider: { "TOK" },
            now: { Date(timeIntervalSince1970: 2_000_000_000) })
    }
    private func wire(_ id: String, title: String, updated: String) -> String {
        #"{"task_id":"\#(id)","title":"\#(title)","urgent":true,"important":false,"client_updated_at":"\#(updated)","client_created_at":"\#(updated)"}"#
    }

    @Test func pullUpsertsNewRemoteTask() async throws {
        let db = try AppDatabase.inMemory(); let repo = GRDBTaskRepository(db); let exec = ListExecutor()
        exec.json = #"{"page":1,"perPage":200,"totalItems":1,"totalPages":1,"items":[\#(wire("r1", title: "Remote", updated: "2026-06-15T09:00:00.000Z"))]}"#
        let (applied, maxApplied) = try await engine(exec, repo).pull(token: "TOK", since: "2026-01-01T00:00:00.000Z")
        #expect(applied == 1)
        let stored = try await repo.fetch(id: "r1")
        #expect(stored?.title == "Remote")
        #expect(maxApplied.map { Int($0.timeIntervalSince1970) } == Int(WireDate.parse("2026-06-15T09:00:00.000Z")!.timeIntervalSince1970))
    }

    @Test func pullSkipsWhenLocalIsNewer() async throws {
        let db = try AppDatabase.inMemory(); let repo = GRDBTaskRepository(db); let exec = ListExecutor()
        // local edited day 2; remote (incoming) edited day 1 → keep local
        let day2 = Date(timeIntervalSince1970: 2_000_000); let day1 = "1970-01-12T13:46:40.000Z"  // ~day 1
        try await repo.upsert(Task(id: "x", title: "Local v2", urgent: false, important: false,
                                   createdAt: day2, updatedAt: day2))
        exec.json = #"{"page":1,"perPage":200,"totalItems":1,"totalPages":1,"items":[\#(wire("x", title: "Remote v1", updated: day1))]}"#
        _ = try await engine(exec, repo).pull(token: "TOK", since: "1970-01-01T00:00:00.000Z")
        #expect(try await repo.fetch(id: "x")?.title == "Local v2")   // local newer → not overwritten
    }

    @Test func pullPreservesDeviceLocalFieldsOnMerge() async throws {
        let db = try AppDatabase.inMemory(); let repo = GRDBTaskRepository(db); let exec = ListExecutor()
        let old = Date(timeIntervalSince1970: 1_000_000)
        var local = Task(id: "x", title: "Local", urgent: false, important: false, createdAt: old, updatedAt: old)
        local.snoozedUntil = Date(timeIntervalSince1970: 1_500_000)   // device-local
        try await repo.upsert(local)
        // remote is NEWER → upsert, but snoozedUntil must stay local
        exec.json = #"{"page":1,"perPage":200,"totalItems":1,"totalPages":1,"items":[\#(wire("x", title: "Remote", updated: "2026-06-15T09:00:00.000Z"))]}"#
        _ = try await engine(exec, repo).pull(token: "TOK", since: "1970-01-01T00:00:00.000Z")
        let merged = try await repo.fetch(id: "x")
        #expect(merged?.title == "Remote")                                       // synced field updated
        #expect(merged?.snoozedUntil == Date(timeIntervalSince1970: 1_500_000))  // device-local preserved
    }
}
