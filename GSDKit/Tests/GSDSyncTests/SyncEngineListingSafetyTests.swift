import Testing
import Foundation
import GSDModel
import GSDStore
@testable import GSDSync

/// Parity S10 and S11 (backlog B-05, B-06). A remote listing the engine can't trust must never
/// delete a local task, and a remote version it can't read must never authorize an overwrite.
struct SyncEngineListingSafetyTests {
    final class ScriptedExecutor: RequestExecuting, @unchecked Sendable {
        var listJSON = #"{"page":1,"perPage":200,"totalItems":0,"totalPages":1,"items":[]}"#
        private(set) var writes: [(method: String, path: String)] = []
        func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let method = request.httpMethod ?? "GET"
            if method == "GET" {
                return (Data(listJSON.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            writes.append((method, request.url!.path))
            let body = #"{"id":"rec_x","task_id":"a","title":"t","urgent":false,"important":false}"#
            let status = method == "DELETE" ? 204 : 200
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    // token with id "u1"
    private static let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJpZCI6InUxIiwiZXhwIjo5OTk5OTk5OTk5fQ.x"

    private func engine(_ db: AppDatabase, _ exec: ScriptedExecutor,
                        cursor: SyncCursor = SyncCursor(defaults: UserDefaults(suiteName: "t.\(UUID().uuidString)")!)) -> SyncEngine {
        SyncEngine(client: PocketBaseClient(baseURL: "https://api.vinny.io", executor: exec),
                   tasks: GRDBTaskRepository(db), queue: GRDBSyncQueueRepository(db),
                   cursor: cursor, deviceId: "dev-A", tokenProvider: { Self.jwt },
                   now: { Date(timeIntervalSince1970: 2_000_000_000) }, throttleMs: 0)
    }
    private func task(_ id: String) -> Task {
        Task(id: id, title: id, urgent: false, important: false,
             createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1))
    }
    private func page(_ items: [String], totalItems: Int? = nil) -> String {
        #"{"page":1,"perPage":200,"totalItems":\#(totalItems ?? items.count),"totalPages":1,"items":[\#(items.joined(separator: ","))]}"#
    }

    // MARK: B-05 — deletion reconcile acts only on a complete, trustworthy listing

    @Test func reconcileKeepsATaskWhoseRemoteRecordHasMalformedFields() async throws {
        let db = try AppDatabase.inMemory(); let tasks = GRDBTaskRepository(db)
        for id in ["a", "b"] { try await tasks.upsert(task(id)) }
        let exec = ScriptedExecutor()
        // b's `tags` is a string, so the full record can't decode. It is still on the server.
        exec.listJSON = page([#"{"id":"rec_a","task_id":"a"}"#, #"{"id":"rec_b","task_id":"b","tags":"oops"}"#])
        let deleted = try await engine(db, exec).reconcileDeletions(token: Self.jwt)
        #expect(deleted == 0)
        #expect(try await tasks.fetch(id: "b") != nil)
    }

    @Test func reconcileDeletesNothingWhenARemoteRecordCannotBeIdentified() async throws {
        let db = try AppDatabase.inMemory(); let tasks = GRDBTaskRepository(db)
        for id in ["a", "b"] { try await tasks.upsert(task(id)) }
        let exec = ScriptedExecutor()
        exec.listJSON = page([#"{"id":"rec_a","task_id":"a"}"#, #"{"id":"rec_x","title":"no task_id"}"#])
        await #expect(throws: RemoteListingIncomplete.self) {
            _ = try await engine(db, exec).reconcileDeletions(token: Self.jwt)
        }
        #expect(try await tasks.fetch(id: "b") != nil)
    }

    @Test func syncReportsAnIncompleteListingAndDeletesNothing() async throws {
        let db = try AppDatabase.inMemory(); let tasks = GRDBTaskRepository(db)
        for id in ["a", "b"] { try await tasks.upsert(task(id)) }
        // A stored cursor skips the first-sync seed, so nothing is protected by the queue.
        let cursor = SyncCursor(defaults: UserDefaults(suiteName: "t.\(UUID().uuidString)")!)
        cursor.advance(maxApplied: Date(timeIntervalSince1970: 1_000))
        let exec = ScriptedExecutor()
        // The server promises two records and sends one.
        exec.listJSON = page([#"{"id":"rec_a","task_id":"a"}"#], totalItems: 2)
        let result = await engine(db, exec, cursor: cursor).sync(trigger: .manual)
        #expect(result.error != nil)
        #expect(result.deleted == 0)
        #expect(try await tasks.fetch(id: "b") != nil)
    }

    // MARK: B-06 — a missing or malformed remote version never authorizes an overwrite

    @Test func pushDoesNotOverwriteWhenTheRemoteVersionIsMissing() async throws {
        let db = try AppDatabase.inMemory(); let queue = GRDBSyncQueueRepository(db)
        let exec = ScriptedExecutor()
        exec.listJSON = page([#"{"id":"rec_a","task_id":"a"}"#])
        try await queue.enqueue(SyncQueueItem(id: "q1", taskId: "a", operation: .update, timestamp: 1, payload: task("a")))
        let (pushed, failed) = try await engine(db, exec).push(token: Self.jwt, owner: "u1")
        #expect(pushed == 0 && failed == 1)
        #expect(exec.writes.isEmpty)
        let pending = try await queue.pending()
        #expect(pending.count == 1 && pending[0].retryCount == 1)   // kept and retried on a later sync
    }

    @Test func pushDoesNotOverwriteWhenTheRemoteVersionIsMalformed() async throws {
        let db = try AppDatabase.inMemory(); let queue = GRDBSyncQueueRepository(db)
        let exec = ScriptedExecutor()
        exec.listJSON = page([#"{"id":"rec_a","task_id":"a","client_updated_at":"yesterday"}"#])
        try await queue.enqueue(SyncQueueItem(id: "q1", taskId: "a", operation: .update, timestamp: 1, payload: task("a")))
        let (pushed, failed) = try await engine(db, exec).push(token: Self.jwt, owner: "u1")
        #expect(pushed == 0 && failed == 1)
        #expect(exec.writes.isEmpty)
    }

    @Test func aMalformedVersionUsesUpTheRetryBudgetLikeAnyFailure() async throws {
        let db = try AppDatabase.inMemory(); let queue = GRDBSyncQueueRepository(db)
        let exec = ScriptedExecutor()
        exec.listJSON = page([#"{"id":"rec_a","task_id":"a"}"#])
        try await queue.enqueue(SyncQueueItem(id: "q1", taskId: "a", operation: .update, timestamp: 1,
                                              retryCount: 4, payload: task("a")))
        _ = try await engine(db, exec).push(token: Self.jwt, owner: "u1")
        let all = try await queue.all()
        #expect(all.count == 1 && all[0].status == .failed)   // kept for Sync Now, never dropped
        #expect(exec.writes.isEmpty)
    }

    @Test func pushStillSendsADeleteWhenTheRemoteVersionIsMissing() async throws {
        // Android parity: the version guard covers creates and updates. A delete carries no
        // payload to compare, and the user asked for the record to go.
        let db = try AppDatabase.inMemory(); let queue = GRDBSyncQueueRepository(db)
        let exec = ScriptedExecutor()
        exec.listJSON = page([#"{"id":"rec_a","task_id":"a"}"#])
        try await queue.enqueue(SyncQueueItem(id: "q1", taskId: "a", operation: .delete, timestamp: 1))
        let (pushed, _) = try await engine(db, exec).push(token: Self.jwt, owner: "u1")
        #expect(pushed == 1)
        #expect(exec.writes.contains { $0.method == "DELETE" && $0.path.hasSuffix("rec_a") })
    }
}
