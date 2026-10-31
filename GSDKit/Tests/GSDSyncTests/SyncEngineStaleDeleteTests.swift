import Testing
import Foundation
import GSDModel
import GSDStore
@testable import GSDSync
@testable import GSDWire

/// B-42 and B-47. A queued delete is stale when the server copy changed after it was queued, and an
/// archive's delete is also stale when the server copy is newer than the version archived (web
/// `isStaleDelete`, Android `remoteEditedAfterQueued` and `remoteEditedAfterArchive`). Then B-04's
/// queued-delete exemption: a delete that push will drop can't hold back a newer remote copy.
struct SyncEngineStaleDeleteTests {
    final class Executor: RequestExecuting, @unchecked Sendable {
        var listJSON = #"{"page":1,"perPage":200,"totalItems":0,"totalPages":1,"items":[]}"#
        private(set) var writes: [String] = []
        func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let method = request.httpMethod ?? "GET"
            func response(_ body: String, _ status: Int = 200) -> (Data, HTTPURLResponse) {
                (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
            if request.url!.path.hasSuffix("/auth-refresh") { return response(#"{"token":"fresh","record":{"id":"u1","email":"e@x"}}"#) }
            if method == "GET" { return response(listJSON) }
            writes.append(method)
            return response("", 204)
        }
    }

    // token with id "u1"
    private static let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJpZCI6InUxIiwiZXhwIjo5OTk5OTk5OTk5fQ.x"
    private static let now = Date(timeIntervalSince1970: 2_000_000_000)   // 2033-05-18T03:33:20Z
    // All 2026-06-15, and all far enough in the past that the 5-minute clamp never applies.
    private static let archivedVersion = WireDate.parse("2026-06-15T08:00:00.000Z")!
    private static let queuedAt = WireDate.parse("2026-06-15T12:00:00.123Z")!
    private static let beforeQueue = "2026-06-15T10:00:00.000Z"
    private static let atQueue = "2026-06-15T12:00:00.123Z"
    private static let afterQueue = "2026-06-15T14:00:00.000Z"

    private func engine(_ db: AppDatabase, _ exec: Executor) -> SyncEngine {
        let cursor = SyncCursor(defaults: UserDefaults(suiteName: "t.\(UUID().uuidString)")!)
        cursor.advance(maxApplied: Date(timeIntervalSince1970: 1_000))   // not a first sync, so no seed
        return SyncEngine(client: PocketBaseClient(baseURL: "https://api.vinny.io", executor: exec),
                          tasks: GRDBTaskRepository(db), queue: GRDBSyncQueueRepository(db),
                          tombstones: GRDBTombstoneRepository(db), cursor: cursor,
                          deviceId: "dev-A", tokenProvider: { Self.jwt }, rawToken: { Self.jwt },
                          now: { Self.now }, throttleMs: 0)
    }
    private func task(updatedAt: Date = archivedVersion) -> Task {
        Task(id: "a", title: "local", urgent: false, important: false,
             createdAt: Date(timeIntervalSince1970: 1), updatedAt: updatedAt)
    }
    private func listing(updated: String) -> Executor {
        let exec = Executor()
        exec.listJSON = #"{"page":1,"perPage":200,"totalItems":1,"totalPages":1,"items":[{"id":"rec_a","task_id":"a","owner":"u1","title":"remote","urgent":false,"important":false,"client_updated_at":"\#(updated)","device_id":"dev-B","updated":"2026-06-15T15:00:00.000Z"}]}"#
        return exec
    }
    private func deleteRow(queuedAt: Date = queuedAt, payload: Task? = nil, status: SyncQueueItem.Status = .pending) -> SyncQueueItem {
        SyncQueueItem(id: "d1", taskId: "a", operation: .delete,
                      timestamp: Int(queuedAt.timeIntervalSince1970 * 1000), payload: payload, status: status)
    }

    // MARK: B-42, any delete

    @Test func aDeleteQueuedBeforeARemoteEditIsDroppedAndTheEditStays() async throws {
        let db = try AppDatabase.inMemory(); let queue = GRDBSyncQueueRepository(db)
        try await queue.enqueue(deleteRow())
        let exec = listing(updated: Self.afterQueue)
        let (pushed, failed) = try await engine(db, exec).push(token: Self.jwt, owner: "u1")
        #expect(exec.writes.isEmpty)
        #expect(pushed == 0 && failed == 0)
        #expect(try await queue.all().isEmpty)   // resolved, not retried
    }

    @Test func aDeleteQueuedAfterTheLastRemoteEditStillDeletes() async throws {
        let db = try AppDatabase.inMemory(); let queue = GRDBSyncQueueRepository(db)
        try await queue.enqueue(deleteRow())
        let exec = listing(updated: Self.beforeQueue)
        let (pushed, _) = try await engine(db, exec).push(token: Self.jwt, owner: "u1")
        #expect(exec.writes == ["DELETE"])
        #expect(pushed == 1)
    }

    // Strictly newer, on the same millisecond math as the rest of LWW.
    @Test func aRemoteEditAtTheSameMillisecondStillDeletes() async throws {
        let db = try AppDatabase.inMemory(); let queue = GRDBSyncQueueRepository(db)
        try await queue.enqueue(deleteRow())
        let exec = listing(updated: Self.atQueue)
        _ = try await engine(db, exec).push(token: Self.jwt, owner: "u1")
        #expect(exec.writes == ["DELETE"])
    }

    // B-44 applies here too: a far-future stamp is never newer, so it can't protect itself forever.
    @Test func aFarFutureRemoteStampDoesNotStopADelete() async throws {
        let db = try AppDatabase.inMemory(); let queue = GRDBSyncQueueRepository(db)
        try await queue.enqueue(deleteRow())
        let exec = listing(updated: "2099-01-01T00:00:00.000Z")
        _ = try await engine(db, exec).push(token: Self.jwt, owner: "u1")
        #expect(exec.writes == ["DELETE"])
    }

    // MARK: B-47, a delete that carries the archived version

    @Test func anArchiveDeleteIsDroppedWhenTheRemoteIsNewerThanTheArchivedVersion() async throws {
        let db = try AppDatabase.inMemory(); let queue = GRDBSyncQueueRepository(db)
        try await queue.enqueue(deleteRow(payload: task()))
        let exec = listing(updated: Self.beforeQueue)   // older than the delete, newer than the version
        let (pushed, _) = try await engine(db, exec).push(token: Self.jwt, owner: "u1")
        #expect(exec.writes.isEmpty)
        #expect(pushed == 0)
        #expect(try await queue.all().isEmpty)
    }

    @Test func anArchiveDeleteStillDeletesWhenTheRemoteHoldsTheArchivedVersion() async throws {
        let db = try AppDatabase.inMemory(); let queue = GRDBSyncQueueRepository(db)
        try await queue.enqueue(deleteRow(payload: task()))
        let exec = listing(updated: "2026-06-15T08:00:00.000Z")
        _ = try await engine(db, exec).push(token: Self.jwt, owner: "u1")
        #expect(exec.writes == ["DELETE"])
    }

    // The normal archive: the server holds exactly the version archived. A sub-millisecond clock must
    // not make the remote read as newer, or every ordinary archive would leave its server copy behind.
    @Test(arguments: [0.0004, 0.0005, 0.0006, 0.1236, 0.9994, 0.9996, 0.3337, 0.6669])
    func anArchiveDeleteStillDeletesAtASubMillisecondVersion(fraction: Double) async throws {
        let db = try AppDatabase.inMemory(); let queue = GRDBSyncQueueRepository(db)
        let version = Date(timeIntervalSince1970: 1_781_510_400 + fraction)   // stored and read back as JSON
        try await queue.enqueue(deleteRow(queuedAt: version.addingTimeInterval(60), payload: task(updatedAt: version)))
        let exec = listing(updated: WireDate.format(version))                 // as this client pushed it
        _ = try await engine(db, exec).push(token: Self.jwt, owner: "u1")
        #expect(exec.writes == ["DELETE"])
    }

    // The same case through the real store, which re-reads the row from SQLite before it archives:
    // what the server holds (this client's own push of the queued create) must match that version.
    @Test(arguments: [0.0004, 0.0005, 0.0006, 0.1236, 0.9994, 0.9996, 0.3337, 0.6669])
    @MainActor func anArchiveThroughTheStoreStillDeletesWhatThisClientPushed(fraction: Double) async throws {
        let db = try AppDatabase.inMemory(); let queue = GRDBSyncQueueRepository(db)
        // The archive comes a minute after the edit, as a person would do it, so this tests the version
        // check alone: the queued-at check has its own same-millisecond test.
        let edited = Date(timeIntervalSince1970: 1_781_510_400 + fraction)
        nonisolated(unsafe) var clock = edited
        let store = TaskStore(repository: GRDBTaskRepository(db, now: { clock }),
                              smartViewRepository: GRDBSmartViewRepository(db),
                              archiveRepository: GRDBArchiveRepository(db, now: { clock }),
                              trashRepository: GRDBTrashRepository(db, now: { clock }),
                              defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!,
                              clock: { clock }, syncQueue: queue)
        try await store.create(task())
        let pushedVersion = try #require(try await queue.all().first?.payload?.updatedAt)
        for row in try await queue.all() { try await queue.remove(id: row.id) }   // the create landed
        clock = edited.addingTimeInterval(60)
        try await store.archive(task())
        let exec = listing(updated: WireDate.format(pushedVersion))
        _ = try await engine(db, exec).push(token: Self.jwt, owner: "u1")
        #expect(exec.writes == ["DELETE"])
    }

    // A delete an older build queued has no payload, so it gets only the B-42 check: a remote newer
    // than any archived version, but older than the delete, doesn't stop it.
    @Test func aDeleteWithNoPayloadGetsOnlyTheQueuedAtCheck() async throws {
        let db = try AppDatabase.inMemory(); let queue = GRDBSyncQueueRepository(db)
        try await queue.enqueue(deleteRow(payload: nil))
        let exec = listing(updated: Self.beforeQueue)
        let (pushed, _) = try await engine(db, exec).push(token: Self.jwt, owner: "u1")
        #expect(exec.writes == ["DELETE"])
        #expect(pushed == 1)
    }

    // MARK: B-04, full sync. Pull runs before push, and the cursor advances past what pull suppresses.

    // Before this change pull suppressed the record, the cursor moved past it, and push then dropped
    // the delete: the task stayed in Trash here and live everywhere else, for good.
    @Test func aRemoteEditNewerThanAQueuedDeleteBringsTheTaskBack() async throws {
        let db = try AppDatabase.inMemory()
        try await GRDBTrashRepository(db).trash(task(), at: Self.queuedAt)
        try await GRDBSyncQueueRepository(db).enqueue(deleteRow())
        let exec = listing(updated: Self.afterQueue)
        let result = await engine(db, exec).sync(trigger: .periodic)
        #expect(result.error == nil)
        #expect(exec.writes.isEmpty)
        #expect(try await GRDBTaskRepository(db).fetch(id: "a")?.title == "remote")
        #expect(try await GRDBTrashRepository(db).fetchAll().isEmpty)
        #expect(try await GRDBSyncQueueRepository(db).all().isEmpty)
    }

    @Test func aRemoteEditOlderThanAQueuedDeleteLeavesItDeleted() async throws {
        let db = try AppDatabase.inMemory()
        try await GRDBTrashRepository(db).trash(task(), at: Self.queuedAt)
        try await GRDBSyncQueueRepository(db).enqueue(deleteRow())
        let exec = listing(updated: Self.beforeQueue)
        let result = await engine(db, exec).sync(trigger: .periodic)
        #expect(result.error == nil)
        #expect(exec.writes == ["DELETE"])
        #expect(try await GRDBTaskRepository(db).fetch(id: "a") == nil)
        #expect(try await GRDBTrashRepository(db).fetchAll().map(\.id) == ["a"])
    }

    // `TaskStore.archive` moves the row before it queues the delete. An edit landing between the two
    // is newer than the tombstone and older than the delete, which push will still send. Bringing the
    // row back would let that delete, then reconcile, remove the task and its archive copy for good.
    @Test func aDeleteThatWillStillLandKeepsTheTombstone() async throws {
        let db = try AppDatabase.inMemory()
        let buriedAt = WireDate.parse("2026-06-15T09:00:00.000Z")!
        try await GRDBArchiveRepository(db).archive(task(), at: buriedAt)
        try await GRDBSyncQueueRepository(db).enqueue(deleteRow())
        let exec = listing(updated: Self.beforeQueue)   // after buriedAt, before queuedAt
        let result = await engine(db, exec).sync(trigger: .periodic)
        #expect(result.error == nil)
        #expect(exec.writes == ["DELETE"])
        #expect(try await GRDBTaskRepository(db).fetch(id: "a") == nil)
        #expect(try await GRDBArchiveRepository(db).fetchAll().map(\.id) == ["a"])
    }

    // In the worst case this device keeps the task archived while others keep it active. Nothing is lost.
    @Test func aStaleArchiveDeleteOlderThanTheTombstoneLeavesTheTaskArchived() async throws {
        let db = try AppDatabase.inMemory()
        let buriedAt = WireDate.parse("2026-06-15T11:00:00.000Z")!
        try await GRDBArchiveRepository(db).archive(task(), at: buriedAt)
        try await GRDBSyncQueueRepository(db).enqueue(deleteRow(payload: task()))
        let exec = listing(updated: Self.beforeQueue)   // newer than the version, older than the archive
        let result = await engine(db, exec).sync(trigger: .periodic)
        #expect(result.error == nil)
        #expect(exec.writes.isEmpty)
        #expect(try await GRDBArchiveRepository(db).fetchAll().map(\.id) == ["a"])
        #expect(try await GRDBSyncQueueRepository(db).all().isEmpty)
    }

    // A failed delete row isn't pushed until a retry revives it, and push then drops it as stale.
    @Test func aStaleFailedDeleteRowDoesNotHoldBackTheNewerCopy() async throws {
        let db = try AppDatabase.inMemory()
        try await GRDBTrashRepository(db).trash(task(), at: Self.queuedAt)
        try await GRDBSyncQueueRepository(db).enqueue(deleteRow(status: .failed))
        let exec = listing(updated: Self.afterQueue)
        _ = await engine(db, exec).sync(trigger: .periodic)
        #expect(exec.writes.isEmpty)
        #expect(try await GRDBTaskRepository(db).fetch(id: "a")?.title == "remote")
    }
}
