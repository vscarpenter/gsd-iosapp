import Testing
import Foundation
import GSDModel
import GSDStore
@testable import GSDSync
@testable import GSDWire

/// B-44. `client_updated_at` comes from the writing device's clock, so a skewed or forged far-future
/// stamp must not win forever. Mirrors the web: push and tombstones treat it as never newer
/// (`isRemoteNewer`, `isRemoteNewerThanArchive`), and ingestion caps it (`clampClientTimestamp`).
struct SyncEngineClockSkewTests {
    final class Executor: RequestExecuting, @unchecked Sendable {
        var json = #"{"page":1,"perPage":200,"totalItems":0,"totalPages":1,"items":[]}"#
        private(set) var writes: [String] = []
        func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let method = request.httpMethod ?? "GET"
            if method != "GET" { writes.append(method) }
            let body = method == "GET" ? json : #"{"id":"rec_a","task_id":"a","title":"t","urgent":false,"important":false}"#
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    // token with id "u1"
    private static let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJpZCI6InUxIiwiZXhwIjo5OTk5OTk5OTk5fQ.x"
    private static let now = Date(timeIntervalSince1970: 2_000_000_000)   // 2033-05-18T03:33:20Z
    private static let ceiling = Date(timeIntervalSince1970: 2_000_000_300)
    private static let farFuture = "2099-01-01T00:00:00.000Z"
    private static let withinWindow = "2033-05-18T03:35:20.000Z"          // now + 2 minutes
    private static let buriedAt = Date(timeIntervalSince1970: 1_900_000_000)
    private static let epoch = "1970-01-01 00:00:00.000Z"

    private func engine(_ db: AppDatabase, _ exec: Executor = Executor()) -> SyncEngine {
        SyncEngine(client: PocketBaseClient(baseURL: "https://api.vinny.io", executor: exec),
                   tasks: GRDBTaskRepository(db), queue: GRDBSyncQueueRepository(db),
                   tombstones: GRDBTombstoneRepository(db),
                   cursor: SyncCursor(defaults: UserDefaults(suiteName: "t.\(UUID().uuidString)")!),
                   deviceId: "dev-A", tokenProvider: { Self.jwt },
                   now: { Self.now }, throttleMs: 0)
    }
    private func task(_ id: String = "a", updatedAt: Date = Date(timeIntervalSince1970: 1)) -> Task {
        Task(id: id, title: "local", urgent: false, important: false,
             createdAt: Date(timeIntervalSince1970: 1), updatedAt: updatedAt)
    }
    private func record(_ id: String = "a", updated: String) -> String {
        #"{"id":"rec_\#(id)","task_id":"\#(id)","owner":"u1","title":"remote","urgent":false,"important":false,"client_updated_at":"\#(updated)","device_id":"dev-B","updated":"2033-05-18T03:00:00.000Z"}"#
    }
    private func listing(updated: String) -> Executor {
        let exec = Executor()
        exec.json = #"{"page":1,"perPage":200,"totalItems":1,"totalPages":1,"items":[\#(record(updated: updated))]}"#
        return exec
    }
    private func realtime(updated: String) -> String {
        #"{"action":"update","record":\#(record(updated: updated))}"#
    }

    // MARK: Push

    // Web `pb-push.test.ts`: a poisoned record must not block a real local edit, or nothing heals it.
    @Test func pushOverwritesARemoteWithAFarFutureStamp() async throws {
        let db = try AppDatabase.inMemory(); let queue = GRDBSyncQueueRepository(db)
        let exec = listing(updated: Self.farFuture)
        let edit = task(updatedAt: Self.now.addingTimeInterval(-60))
        try await queue.enqueue(SyncQueueItem(id: "q1", taskId: "a", operation: .update, timestamp: 1, payload: edit))
        let (pushed, failed) = try await engine(db, exec).push(token: Self.jwt, owner: "u1")
        #expect(exec.writes == ["PATCH"])
        #expect(pushed == 1 && failed == 0)
    }

    @Test func pushStillDropsAnEditOlderThanAStampInsideTheWindow() async throws {
        let db = try AppDatabase.inMemory(); let queue = GRDBSyncQueueRepository(db)
        let exec = listing(updated: Self.withinWindow)
        let edit = task(updatedAt: Self.now.addingTimeInterval(-60))
        try await queue.enqueue(SyncQueueItem(id: "q1", taskId: "a", operation: .update, timestamp: 1, payload: edit))
        _ = try await engine(db, exec).push(token: Self.jwt, owner: "u1")
        #expect(exec.writes.isEmpty)
        #expect(try await queue.pending().isEmpty)
    }

    // MARK: Pull and realtime ingestion

    @Test func pullStoresANewFarFutureRecordAtTheCeiling() async throws {
        let db = try AppDatabase.inMemory()
        _ = try await engine(db, listing(updated: Self.farFuture)).pull(token: Self.jwt, since: Self.epoch)
        let stored = try await GRDBTaskRepository(db).fetch(id: "a")
        #expect(stored?.title == "remote")
        #expect(stored?.updatedAt == Self.ceiling)   // a stored 2099 would beat every later edit
    }

    @Test func pullAppliesAFarFutureRecordOverALiveRowAtTheCeiling() async throws {
        let db = try AppDatabase.inMemory(); let tasks = GRDBTaskRepository(db)
        try await tasks.upsert(task())
        let (applied, conflicts, _) = try await engine(db, listing(updated: Self.farFuture)).pull(token: Self.jwt, since: Self.epoch)
        let stored = try await tasks.fetch(id: "a")
        #expect(applied == 1 && conflicts == 1)
        #expect(stored?.title == "remote")
        #expect(stored?.updatedAt == Self.ceiling)
    }

    @Test func pullLeavesAStampInsideTheWindowUncapped() async throws {
        let db = try AppDatabase.inMemory()
        _ = try await engine(db, listing(updated: Self.withinWindow)).pull(token: Self.jwt, since: Self.epoch)
        #expect(try await GRDBTaskRepository(db).fetch(id: "a")?.updatedAt == WireDate.parse(Self.withinWindow))
    }

    @Test func realtimeAppliesAFarFutureRecordOverALiveRowAtTheCeiling() async throws {
        let db = try AppDatabase.inMemory(); let tasks = GRDBTaskRepository(db)
        try await tasks.upsert(task())
        await engine(db).applyRealtime(rawData: realtime(updated: Self.farFuture))
        let stored = try await tasks.fetch(id: "a")
        #expect(stored?.title == "remote")
        #expect(stored?.updatedAt == Self.ceiling)
    }

    @Test func realtimeStoresANewFarFutureRecordAtTheCeiling() async throws {
        let db = try AppDatabase.inMemory()
        await engine(db).applyRealtime(rawData: realtime(updated: Self.farFuture))
        #expect(try await GRDBTaskRepository(db).fetch(id: "a")?.updatedAt == Self.ceiling)
    }

    // MARK: Tombstones

    // Web `pb-pull.test.ts`: comparing the capped value instead would resurrect the tombstone.
    @Test func pullLeavesAnArchivedTaskArchivedWhenTheRemoteStampIsFarFuture() async throws {
        let db = try AppDatabase.inMemory()
        try await GRDBArchiveRepository(db).archive(task(), at: Self.buriedAt)
        let (applied, _, _) = try await engine(db, listing(updated: Self.farFuture)).pull(token: Self.jwt, since: Self.epoch)
        #expect(applied == 0)
        #expect(try await GRDBTaskRepository(db).fetch(id: "a") == nil)
        #expect(try await GRDBArchiveRepository(db).fetchAll().map(\.id) == ["a"])
    }

    @Test func pullLeavesATrashedTaskTrashedWhenTheRemoteStampIsFarFuture() async throws {
        let db = try AppDatabase.inMemory()
        try await GRDBTrashRepository(db).trash(task(), at: Self.buriedAt)
        _ = try await engine(db, listing(updated: Self.farFuture)).pull(token: Self.jwt, since: Self.epoch)
        #expect(try await GRDBTaskRepository(db).fetch(id: "a") == nil)
        #expect(try await GRDBTrashRepository(db).fetchAll().map(\.id) == ["a"])
    }

    @Test func realtimeLeavesAnArchivedTaskArchivedWhenTheRemoteStampIsFarFuture() async throws {
        let db = try AppDatabase.inMemory()
        try await GRDBArchiveRepository(db).archive(task(), at: Self.buriedAt)
        await engine(db).applyRealtime(rawData: realtime(updated: Self.farFuture))
        #expect(try await GRDBTaskRepository(db).fetch(id: "a") == nil)
        #expect(try await GRDBArchiveRepository(db).fetchAll().map(\.id) == ["a"])
    }

    @Test func pullBringsBackAnArchivedTaskWhenTheNewerStampIsInsideTheWindow() async throws {
        let db = try AppDatabase.inMemory()
        try await GRDBArchiveRepository(db).archive(task(), at: Self.buriedAt)
        _ = try await engine(db, listing(updated: Self.withinWindow)).pull(token: Self.jwt, since: Self.epoch)
        #expect(try await GRDBTaskRepository(db).fetch(id: "a")?.title == "remote")
        #expect(try await GRDBArchiveRepository(db).fetchAll().isEmpty)
    }
}
