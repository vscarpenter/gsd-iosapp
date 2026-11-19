import Testing
import Foundation
import GSDModel
import GSDStore
@testable import GSDSync
@testable import GSDWire

/// A refused or revoked token lists `tasks` as 200 with no items, the same answer an empty account
/// gives. So a push that is about to act on a task missing from the listing (a create, an update with
/// no listing entry, a delete with no listing entry) confirms the account with auth-refresh first,
/// once per push. A 401 or 403 anywhere in the push ends it and charges no row.
struct SyncEnginePushIdentityTests {
    final class Executor: RequestExecuting, @unchecked Sendable {
        var listJSON = #"{"page":1,"perPage":200,"totalItems":0,"totalPages":1,"items":[]}"#
        var refreshStatus = 200
        var refreshRecordId = "u1"
        var writeStatus = 200
        private(set) var refreshes = 0
        private(set) var writes: [String] = []
        func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let method = request.httpMethod ?? "GET"
            func response(_ body: String, _ status: Int = 200) -> (Data, HTTPURLResponse) {
                (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
            if request.url!.path.hasSuffix("/auth-refresh") {
                refreshes += 1
                let confirmed = #"{"token":"fresh","record":{"id":"\#(refreshRecordId)","email":"e@x"}}"#
                return response(refreshStatus == 200 ? confirmed : #"{"message":"nope"}"#, refreshStatus)
            }
            if method == "GET" { return response(listJSON) }
            writes.append(method)
            if writeStatus != 200 { return response(#"{"message":"nope"}"#, writeStatus) }
            if method == "DELETE" { return response("", 204) }
            return response(Self.record("a", recordId: "rec_a"))
        }
        static func record(_ taskId: String, recordId: String) -> String {
            #"{"id":"\#(recordId)","task_id":"\#(taskId)","owner":"u1","title":"remote","urgent":false,"important":false,"client_updated_at":"2026-06-15T10:00:00.000Z","device_id":"dev-B","updated":"2026-06-15T15:00:00.000Z"}"#
        }
    }

    // token with id "u1"
    private static let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJpZCI6InUxIiwiZXhwIjo5OTk5OTk5OTk5fQ.x"

    private func engine(_ db: AppDatabase, _ exec: Executor) -> SyncEngine {
        let cursor = SyncCursor(defaults: UserDefaults(suiteName: "t.\(UUID().uuidString)")!)
        cursor.advance(maxApplied: Date(timeIntervalSince1970: 1_000))
        return SyncEngine(client: PocketBaseClient(baseURL: "https://api.vinny.io", executor: exec),
                          tasks: GRDBTaskRepository(db), queue: GRDBSyncQueueRepository(db),
                          tombstones: GRDBTombstoneRepository(db), cursor: cursor,
                          deviceId: "dev-A", tokenProvider: { Self.jwt }, rawToken: { Self.jwt },
                          now: { Date(timeIntervalSince1970: 2_000_000_000) }, throttleMs: 0)
    }
    private func task(_ id: String) -> Task {
        Task(id: id, title: id, urgent: false, important: false,
             createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1_900_000_000))
    }
    private func row(_ id: String, _ taskId: String, _ op: SyncQueueItem.Operation, at ms: Int) -> SyncQueueItem {
        SyncQueueItem(id: id, taskId: taskId, operation: op, timestamp: ms,
                      payload: op == .delete ? nil : task(taskId))
    }
    private func listing(_ taskIds: [String]) -> String {
        let items = taskIds.map { Executor.record($0, recordId: "rec_\($0)") }.joined(separator: ",")
        return #"{"page":1,"perPage":200,"totalItems":\#(taskIds.count),"totalPages":1,"items":[\#(items)]}"#
    }
    private func seeded(_ db: AppDatabase, ids: [String]) async throws {
        for id in ids { try await GRDBTaskRepository(db).upsert(task(id)) }
    }

    @Test("a refused token keeps a queued delete for an unlisted task")
    func refusedTokenKeepsDelete() async throws {
        let db = try AppDatabase.inMemory(); let queue = GRDBSyncQueueRepository(db)
        try await queue.enqueue(row("d1", "a", .delete, at: 1))
        let exec = Executor(); exec.refreshStatus = 401
        await #expect(throws: (any Error).self) { _ = try await engine(db, exec).push(token: Self.jwt, owner: "u1") }
        let pending = try await queue.pending()
        #expect(pending.map(\.id) == ["d1"] && pending.first?.retryCount == 0)
        #expect(exec.writes.isEmpty)
    }

    @Test("a refused token keeps a queued update for an unlisted task")
    func refusedTokenKeepsUpdate() async throws {
        let db = try AppDatabase.inMemory(); let queue = GRDBSyncQueueRepository(db)
        try await seeded(db, ids: ["a"])
        try await queue.enqueue(row("u1", "a", .update, at: 1))
        let exec = Executor(); exec.refreshStatus = 401
        await #expect(throws: (any Error).self) { _ = try await engine(db, exec).push(token: Self.jwt, owner: "u1") }
        let pending = try await queue.pending()
        #expect(pending.map(\.id) == ["u1"] && pending.first?.retryCount == 0)
        #expect(exec.writes.isEmpty)
    }

    @Test("another account's token keeps every queued row")
    func anotherAccountKeepsEveryRow() async throws {
        let db = try AppDatabase.inMemory(); let queue = GRDBSyncQueueRepository(db)
        try await seeded(db, ids: ["b"])
        try await queue.enqueue(row("d1", "a", .delete, at: 1))
        try await queue.enqueue(row("c1", "b", .create, at: 2))
        let exec = Executor(); exec.refreshRecordId = "u2"
        await #expect(throws: SyncIdentityMismatch.self) { _ = try await engine(db, exec).push(token: Self.jwt, owner: "u1") }
        let pending = try await queue.pending()
        #expect(pending.map(\.id) == ["d1", "c1"] && pending.allSatisfy { $0.retryCount == 0 })
        #expect(exec.writes.isEmpty)
    }

    @Test("a confirmed session drops a delete for an unlisted task")
    func confirmedSessionDropsDelete() async throws {
        let db = try AppDatabase.inMemory(); let queue = GRDBSyncQueueRepository(db)
        try await queue.enqueue(row("d1", "a", .delete, at: 1))
        let exec = Executor()
        _ = try await engine(db, exec).push(token: Self.jwt, owner: "u1")
        #expect(try await queue.all().isEmpty)
        #expect(exec.writes.isEmpty)
        #expect(exec.refreshes == 1)
    }

    @Test("one push confirms identity once across several absences")
    func confirmsOncePerPush() async throws {
        let db = try AppDatabase.inMemory(); let queue = GRDBSyncQueueRepository(db)
        try await seeded(db, ids: ["b", "c"])
        try await queue.enqueue(row("c1", "b", .create, at: 1))
        try await queue.enqueue(row("c2", "c", .create, at: 2))
        try await queue.enqueue(row("d1", "a", .delete, at: 3))
        let exec = Executor()
        _ = try await engine(db, exec).push(token: Self.jwt, owner: "u1")
        #expect(exec.refreshes == 1)
    }

    @Test("a push with every task listed makes no auth-refresh")
    func listedTasksNeedNoConfirmation() async throws {
        let db = try AppDatabase.inMemory(); let queue = GRDBSyncQueueRepository(db)
        try await seeded(db, ids: ["a"])
        try await queue.enqueue(row("u1", "a", .update, at: 1))
        let exec = Executor(); exec.listJSON = listing(["a"])
        _ = try await engine(db, exec).push(token: Self.jwt, owner: "u1")
        #expect(exec.refreshes == 0)
        #expect(exec.writes == ["PATCH"])
    }

    @Test("a refused write ends the push without charging the row", arguments: [401, 403])
    func refusedWriteEndsPush(status: Int) async throws {
        let db = try AppDatabase.inMemory(); let queue = GRDBSyncQueueRepository(db)
        try await seeded(db, ids: ["a", "b"])
        try await queue.enqueue(row("u1", "a", .update, at: 1))
        try await queue.enqueue(row("u2", "b", .update, at: 2))
        let exec = Executor(); exec.listJSON = listing(["a", "b"]); exec.writeStatus = status
        await #expect(throws: (any Error).self) { _ = try await engine(db, exec).push(token: Self.jwt, owner: "u1") }
        let pending = try await queue.pending()
        #expect(pending.map(\.id) == ["u1", "u2"] && pending.allSatisfy { $0.retryCount == 0 })
        #expect(exec.writes.count == 1)
    }
}
