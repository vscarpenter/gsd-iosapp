import Testing
import Foundation
import GSDModel
import GSDStore
@testable import GSDSync
@testable import GSDWire

/// IOS-SYNC-ID. The tasks list rule filters rows, so a token the server rejects lists as 200 with zero
/// items (`sprint/findings/guest-listing.md`), the same answer an empty account gets. Only auth-refresh
/// tells them apart, so reconcile asks it before deleting anything, as Android's `confirmIdentity` does.
struct SyncEngineSessionConfirmTests {
    final class Executor: RequestExecuting, @unchecked Sendable {
        var listJSON = #"{"page":1,"perPage":200,"totalItems":0,"totalPages":1,"items":[]}"#
        var refreshStatus = 200
        var refreshRecordId = "u1"
        var offline = false
        private(set) var refreshes = 0
        func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            func response(_ body: String, _ status: Int = 200) -> (Data, HTTPURLResponse) {
                (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
            guard request.url!.path.hasSuffix("/auth-refresh") else { return response(listJSON) }
            refreshes += 1
            if offline { throw URLError(.notConnectedToInternet) }
            let confirmed = #"{"token":"fresh","record":{"id":"\#(refreshRecordId)","email":"e@x"}}"#
            return response(refreshStatus == 200 ? confirmed : #"{"message":"nope"}"#, refreshStatus)
        }
    }

    // token with id "u1"
    private static let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJpZCI6InUxIiwiZXhwIjo5OTk5OTk5OTk5fQ.x"

    private func engine(_ db: AppDatabase, _ exec: Executor, cursor: SyncCursor? = nil) -> SyncEngine {
        SyncEngine(client: PocketBaseClient(baseURL: "https://api.vinny.io", executor: exec),
                   tasks: GRDBTaskRepository(db), queue: GRDBSyncQueueRepository(db),
                   cursor: cursor ?? SyncCursor(defaults: UserDefaults(suiteName: "t.\(UUID().uuidString)")!),
                   deviceId: "dev-A", tokenProvider: { Self.jwt },
                   now: { Date(timeIntervalSince1970: 2_000_000_000) }, throttleMs: 0)
    }
    private func task(_ id: String) -> Task {
        Task(id: id, title: id, urgent: false, important: false,
             createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1))
    }
    private func seededDatabase() async throws -> AppDatabase {
        let db = try AppDatabase.inMemory()
        for id in ["a", "b"] { try await GRDBTaskRepository(db).upsert(task(id)) }
        return db
    }
    private func expectBothTasksKept(_ db: AppDatabase) async throws {
        #expect(try await GRDBTaskRepository(db).fetchAll().count == 2)
    }

    @Test func aRejectedAuthRefreshWithAnEmptyListingDeletesNothing() async throws {
        let db = try await seededDatabase()
        let exec = Executor(); exec.refreshStatus = 401
        await #expect(throws: (any Error).self) {
            _ = try await engine(db, exec).reconcileDeletions(token: Self.jwt, owner: "u1")
        }
        try await expectBothTasksKept(db)
    }

    // Forbidden, rate limited, and server error: none of them confirm the session.
    @Test(arguments: [403, 429, 500, 503])
    func anyOtherFailedAuthRefreshDeletesNothing(status: Int) async throws {
        let db = try await seededDatabase()
        let exec = Executor(); exec.refreshStatus = status
        await #expect(throws: (any Error).self) {
            _ = try await engine(db, exec).reconcileDeletions(token: Self.jwt, owner: "u1")
        }
        try await expectBothTasksKept(db)
    }

    @Test func anAuthRefreshThatCantReachTheServerDeletesNothing() async throws {
        let db = try await seededDatabase()
        let exec = Executor(); exec.offline = true
        await #expect(throws: (any Error).self) {
            _ = try await engine(db, exec).reconcileDeletions(token: Self.jwt, owner: "u1")
        }
        try await expectBothTasksKept(db)
    }

    @Test func aSessionForAnotherAccountDeletesNothing() async throws {
        let db = try await seededDatabase()
        let exec = Executor(); exec.refreshRecordId = "someone-else"
        await #expect(throws: SyncIdentityMismatch.self) {
            _ = try await engine(db, exec).reconcileDeletions(token: Self.jwt, owner: "u1")
        }
        try await expectBothTasksKept(db)
    }

    // End to end through `sync()`: the run reports the failure and leaves the cursor where it was.
    @Test func aRejectedSessionSurfacesAsASyncErrorAndHoldsTheCursor() async throws {
        let db = try await seededDatabase()
        let cursor = SyncCursor(defaults: UserDefaults(suiteName: "t.\(UUID().uuidString)")!)
        cursor.advance(maxApplied: Date(timeIntervalSince1970: 1_000))
        let before = cursor.load()
        let exec = Executor(); exec.refreshStatus = 401
        let result = await engine(db, exec, cursor: cursor).sync(trigger: .periodic)
        #expect(result.error != nil && result.deleted == 0)
        #expect(cursor.load() == before)
        try await expectBothTasksKept(db)
    }

    // A real empty account is still an empty account: the check must not block a true remote delete.
    @Test func aConfirmedSessionWithAnEmptyListingStillDeletes() async throws {
        let db = try await seededDatabase()
        let exec = Executor()
        let deleted = try await engine(db, exec).reconcileDeletions(token: Self.jwt, owner: "u1")
        #expect(deleted == 2)
        #expect(try await GRDBTaskRepository(db).fetchAll().isEmpty)
        #expect(exec.refreshes == 1)   // once per run, not once per task
    }

    @Test func aRunWithNothingToDeleteMakesNoExtraRequest() async throws {
        let db = try await seededDatabase()
        let queue = GRDBSyncQueueRepository(db)
        try await queue.enqueue(SyncQueueItem(id: "q1", taskId: "a", operation: .update, timestamp: 1, payload: task("a")))
        let exec = Executor(); exec.refreshStatus = 401
        exec.listJSON = #"{"page":1,"perPage":200,"totalItems":1,"totalPages":1,"items":[{"id":"rec_b","task_id":"b"}]}"#
        let deleted = try await engine(db, exec).reconcileDeletions(token: Self.jwt, owner: "u1")
        #expect(deleted == 0)
        #expect(exec.refreshes == 0)
    }
}
