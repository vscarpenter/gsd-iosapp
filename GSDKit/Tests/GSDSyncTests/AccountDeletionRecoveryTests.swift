import Testing
import Foundation
import GSDModel
import GSDStore
@testable import GSDSync
@testable import GSDWire

/// A deletion can erase server tasks and still fail on the user record. The fix ends the session on
/// that outcome. These pin the two engine facts the fix rests on, against a server that really
/// lost the rows: a surviving cursor would delete the local tasks, and a reset one keeps them.
struct AccountDeletionRecoveryTests {
    /// Starts with no rows, as after an erase, and keeps what the client uploads.
    final class ErasedServer: RequestExecuting, @unchecked Sendable {
        private var records: [String: String] = [:]   // task_id to record id
        func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            func response(_ body: String) -> (Data, HTTPURLResponse) {
                (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            if request.url!.path.hasSuffix("/auth-refresh") {
                return response(#"{"token":"fresh","record":{"id":"u1","email":"e@x"}}"#)
            }
            if request.httpMethod == "POST" {
                let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
                let taskId = body?["task_id"] as? String ?? "unknown"
                records[taskId] = "rec-\(taskId)"
                return response(#"{"id":"rec-\#(taskId)","task_id":"\#(taskId)","title":"t","urgent":false,"important":false}"#)
            }
            let items = records.map {
                #"{"task_id":"\#($0.key)","id":"\#($0.value)","title":"t","urgent":false,"important":false,"client_updated_at":"2020-01-01T00:00:00.000Z"}"#
            }.joined(separator: ",")
            return response(#"{"page":1,"perPage":200,"totalItems":\#(records.count),"totalPages":1,"items":[\#(items)]}"#)
        }
    }

    // token with id "u1"
    private static let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJpZCI6InUxIiwiZXhwIjo5OTk5OTk5OTk5fQ.x"

    private func setup() async throws -> (SyncEngine, GRDBTaskRepository) {
        let db = try AppDatabase.inMemory()
        let tasks = GRDBTaskRepository(db)
        for id in ["a", "b"] {
            try await tasks.upsert(Task(id: id, title: id, urgent: false, important: false,
                                        createdAt: Date(timeIntervalSince1970: 1),
                                        updatedAt: Date(timeIntervalSince1970: 1)))
        }
        let cursor = SyncCursor(defaults: UserDefaults(suiteName: "t.\(UUID().uuidString)")!)
        cursor.advance(maxApplied: Date(timeIntervalSince1970: 1_900_000_000))   // this device has synced
        let engine = SyncEngine(client: PocketBaseClient(baseURL: "https://api.vinny.io", executor: ErasedServer()),
                                tasks: tasks, queue: GRDBSyncQueueRepository(db), cursor: cursor,
                                deviceId: "dev-A", tokenProvider: { Self.jwt },
                                now: { Date(timeIntervalSince1970: 2_000_000_000) }, throttleMs: 0)
        return (engine, tasks)
    }

    @Test func aSessionThatStaysOpenLosesTheLocalTasksOnItsNextSync() async throws {
        let (engine, tasks) = try await setup()
        _ = await engine.sync(trigger: .periodic)
        #expect(try await tasks.fetchAll().isEmpty)
    }

    @Test func signingOutThenBackInKeepsTheLocalTasks() async throws {
        let (engine, tasks) = try await setup()
        await engine.resetCursor()   // what `SyncCoordinator.signedOut` does
        _ = await engine.sync(trigger: .signIn)
        #expect(try await tasks.fetchAll().map(\.id).sorted() == ["a", "b"])
    }
}
