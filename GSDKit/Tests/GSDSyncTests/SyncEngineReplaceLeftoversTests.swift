import Testing
import Foundation
import GSDModel
import GSDStore
@testable import GSDSync
@testable import GSDWire

/// Import Replace removes a task whose update was sent, failed, and is waiting out its backoff. The app
/// drains right after a Replace, so the task's delete lands while that update still waits. If the update
/// were still queued when it came due, the server would no longer list the task, and it would POST it back.
struct SyncEngineReplaceLeftoversTests {
    private final class Clock: @unchecked Sendable { var date: Date; init(_ d: Date) { date = d } }
    private static let listed = "2026-11-19T17:00:00.000Z"
    private static let now = WireDate.parse("2026-11-19T18:00:00.000Z")!

    private static func jwt(_ id: String) -> String {
        let payload = Data(#"{"id":"\#(id)","exp":9999999999}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "h.\(payload).s"
    }

    private struct Rig {
        let store: TaskStore
        let tasks: GRDBTaskRepository
        let engine: SyncEngine
        let clock: Clock
    }

    /// A real store and engine over one database, sharing one clock, for an account that has synced
    /// before (so a full sync runs no first-sync seed and no backfill). Tasks `r` and `k` are live here
    /// and listed on the server as `rec1` and `rec2` at the same version.
    @MainActor private func rig(_ exec: InFlightExecutor) async throws -> Rig {
        await exec.base.put(recordId: "rec1", taskId: "r", version: Self.listed)
        await exec.base.put(recordId: "rec2", taskId: "k", version: Self.listed)
        let clock = Clock(Self.now)
        let db = try AppDatabase.inMemory()
        let queue = GRDBSyncQueueRepository(db)
        let tasks = GRDBTaskRepository(db)
        let store = TaskStore(repository: tasks, smartViewRepository: GRDBSmartViewRepository(db),
                              archiveRepository: GRDBArchiveRepository(db), trashRepository: GRDBTrashRepository(db),
                              defaults: UserDefaults(suiteName: "replace.\(UUID().uuidString)")!,
                              clock: { clock.date }, syncQueue: queue)
        let cursor = SyncCursor(defaults: UserDefaults(suiteName: "replace.\(UUID().uuidString)")!)
        cursor.advance(maxApplied: Date(timeIntervalSince1970: 1_000)); cursor.markBackfilled()
        let token = Self.jwt("u1")
        let engine = SyncEngine(client: PocketBaseClient(baseURL: "https://guarded.test", executor: exec),
                                tasks: tasks, queue: queue, tombstones: GRDBTombstoneRepository(db), cursor: cursor,
                                deviceId: "ios", tokenProvider: { token }, rawToken: { token },
                                now: { clock.date }, throttleMs: 0)
        try await tasks.upsert(listedTask("r"))
        try await tasks.upsert(listedTask("k"))
        return Rig(store: store, tasks: tasks, engine: engine, clock: clock)
    }

    private func listedTask(_ id: String, title: String? = nil) -> Task {
        Task(id: id, title: title ?? id, urgent: false, important: false,
             createdAt: WireDate.parse("2026-11-01T00:00:00.000Z")!, updatedAt: WireDate.parse(Self.listed)!)
    }

    @Test("I3: Import Replace doesn't POST back a removed task whose update was waiting out its backoff")
    @MainActor func replaceDoesNotPostARemovedTaskBack() async throws {
        let exec = InFlightExecutor(GuardedServer(), method: "PATCH", failInstead: true)
        let r = try await rig(exec)
        try await r.store.save(listedTask("r", title: "edited"))
        exec.hook = {}                                   // the edit's PATCH gets a 500, so it waits 5 seconds
        #expect(await r.engine.pushNow().failed == 1)
        r.clock.date = Self.now.addingTimeInterval(2)    // inside the backoff
        let backup = TaskExport(tasks: [listedTask("k")], exportedAt: Self.now)
        try await r.store.importTasks(try TaskExport.encode(backup), mode: .replace)
        _ = await r.engine.flushDeletes()                // the drain the app runs right after a Replace
        #expect(await exec.base.holds("rec1") == false)
        r.clock.date = Self.now.addingTimeInterval(600)
        let result = await r.engine.sync(trigger: .manual)
        #expect(result.error == nil)
        let server = exec.base
        let deletes = await server.deletes.map(\.recordId)
        let patches = await server.patches.map(\.recordId)   // the 500 never reached the server, so this is k's import
        let posts = await server.collectionWrites
        let live = try await r.tasks.fetch(id: "r")
        let listed = await server.holds("rec1")
        let reposted = await server.title(of: "rec_new")     // a POST stores its record as rec_new
        #expect(deletes == ["rec1"])
        #expect(patches == ["rec2"])                         // the import's update reached the server, and r's didn't
        #expect(posts.isEmpty)
        #expect(live == nil)
        #expect(!listed)
        #expect(reposted == nil)
    }
}
