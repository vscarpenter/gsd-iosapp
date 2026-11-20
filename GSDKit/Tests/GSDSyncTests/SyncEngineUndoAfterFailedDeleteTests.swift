import Testing
import Foundation
import GSDModel
import GSDStore
@testable import GSDSync
@testable import GSDWire

/// Undo from Trash, or Restore from the archive, after the task's delete was sent and failed. That
/// delete waits out its backoff, so the push the user's action schedules sends the restored task
/// on its own, over the record the server still lists.
struct SyncEngineUndoAfterFailedDeleteTests {
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
        let queue: GRDBSyncQueueRepository
        let engine: SyncEngine
        let clock: Clock
    }

    /// A real store and engine over one database, sharing one clock, for an account that has synced
    /// before (so a full sync runs no first-sync seed and no backfill). Task `a` is live here and
    /// listed on the server as `rec1` at the same version.
    @MainActor private func rig(_ exec: InFlightExecutor) async throws -> Rig {
        await exec.base.put(recordId: "rec1", taskId: "a", version: Self.listed)
        let clock = Clock(Self.now)
        let db = try AppDatabase.inMemory()
        let queue = GRDBSyncQueueRepository(db)
        let tasks = GRDBTaskRepository(db)
        let store = TaskStore(repository: tasks, smartViewRepository: GRDBSmartViewRepository(db),
                              archiveRepository: GRDBArchiveRepository(db), trashRepository: GRDBTrashRepository(db),
                              defaults: UserDefaults(suiteName: "undo.\(UUID().uuidString)")!,
                              clock: { clock.date }, syncQueue: queue)
        let cursor = SyncCursor(defaults: UserDefaults(suiteName: "undo.\(UUID().uuidString)")!)
        cursor.advance(maxApplied: Date(timeIntervalSince1970: 1_000)); cursor.markBackfilled()
        let token = Self.jwt("u1")
        let engine = SyncEngine(client: PocketBaseClient(baseURL: "https://guarded.test", executor: exec),
                                tasks: tasks, queue: queue, tombstones: GRDBTombstoneRepository(db), cursor: cursor,
                                deviceId: "ios", tokenProvider: { token }, rawToken: { token },
                                now: { clock.date }, throttleMs: 0)
        try await tasks.upsert(listedTask())
        return Rig(store: store, tasks: tasks, queue: queue, engine: engine, clock: clock)
    }

    private func listedTask() -> Task {
        Task(id: "a", title: "a", urgent: false, important: false,
             createdAt: WireDate.parse("2026-11-01T00:00:00.000Z")!, updatedAt: WireDate.parse(Self.listed)!)
    }

    /// The first DELETE gets a 500 and is charged, so it waits out a 5 second backoff.
    private func failTheFirstDelete(_ r: Rig, _ exec: InFlightExecutor) async {
        exec.hook = {}
        let result = await r.engine.pushNow()
        #expect(result.failed == 1)
    }

    @Test("I2: Undo from Trash after a failed DELETE keeps the task on both sides")
    @MainActor func undoAfterAFailedTrashDeleteKeepsTheTask() async throws {
        let exec = InFlightExecutor(GuardedServer(), method: "DELETE", failInstead: true)
        let r = try await rig(exec)
        try await r.store.delete(listedTask())
        await failTheFirstDelete(r, exec)
        r.clock.date = Self.now.addingTimeInterval(2)   // inside the backoff
        try await r.store.restoreFromTrash(id: "a")
        _ = await r.engine.pushNow()                    // the push the Undo schedules
        r.clock.date = Self.now.addingTimeInterval(600)
        let result = await r.engine.sync(trigger: .manual)
        #expect(result.error == nil)
        let server = exec.base
        let deletes = await server.deletes.map(\.recordId)   // the 500 never reached the server, so these came after the Undo
        let patches = await server.patches.map(\.recordId)
        let posts = await server.collectionWrites
        let live = try await r.tasks.fetch(id: "a")
        let listed = await server.holds("rec1")
        #expect(deletes.isEmpty)
        #expect(patches == ["rec1"])
        #expect(posts.isEmpty)
        #expect(live != nil)
        #expect(listed)
    }

    @Test("Undo after the Trash's DELETE landed POSTs the task back")
    @MainActor func undoAfterTheDeleteLandedPostsTheTaskBack() async throws {
        let exec = InFlightExecutor(GuardedServer(), method: "DELETE", failInstead: false)
        let r = try await rig(exec)
        try await r.store.delete(listedTask())
        _ = await r.engine.pushNow()
        #expect(await exec.base.holds("rec1") == false)
        try await r.store.restoreFromTrash(id: "a")
        _ = await r.engine.pushNow()
        #expect(await exec.base.collectionWrites == ["POST /api/collections/tasks/records"])
        #expect(await exec.base.holds("rec_new"))
        #expect(try await r.tasks.fetch(id: "a") != nil)
    }

    @Test("Undo while the Trash's DELETE is in flight and lands: the next push POSTs the task back")
    @MainActor func inFlightDeleteThatLandsDuringUndo() async throws {
        let exec = InFlightExecutor(GuardedServer(), method: "DELETE", failInstead: false)
        let r = try await rig(exec)
        try await r.store.delete(listedTask())
        exec.hook = { try await r.store.restoreFromTrash(id: "a") }
        _ = await r.engine.pushNow()
        #expect(await exec.base.holds("rec1") == false)
        _ = await r.engine.pushNow()
        #expect(await exec.base.collectionWrites == ["POST /api/collections/tasks/records"])
        #expect(await exec.base.holds("rec_new"))
        #expect(try await r.tasks.fetch(id: "a") != nil)
    }

    @Test("Undo while the Trash's DELETE is in flight and fails: the failure doesn't put the delete back")
    @MainActor func inFlightDeleteThatFailsDuringUndo() async throws {
        let exec = InFlightExecutor(GuardedServer(), method: "DELETE", failInstead: true)
        let r = try await rig(exec)
        try await r.store.delete(listedTask())
        exec.hook = { try await r.store.restoreFromTrash(id: "a") }
        _ = await r.engine.pushNow()
        let queued = try await r.queue.all().filter { $0.taskId == "a" }.map(\.operation)
        let live = try await r.tasks.fetch(id: "a")
        #expect(queued == [.create])
        #expect(live != nil)
    }

    @Test("Restore from the archive after a failed DELETE keeps the task on both sides")
    @MainActor func archiveRestoreAfterAFailedDeleteKeepsTheTask() async throws {
        let exec = InFlightExecutor(GuardedServer(), method: "DELETE", failInstead: true)
        let r = try await rig(exec)
        try await r.store.archive(listedTask())
        await failTheFirstDelete(r, exec)
        r.clock.date = Self.now.addingTimeInterval(2)   // inside the backoff
        try await r.store.restore(listedTask())
        _ = await r.engine.pushNow()                    // the push the Restore schedules
        r.clock.date = Self.now.addingTimeInterval(600)
        let result = await r.engine.sync(trigger: .manual)
        #expect(result.error == nil)
        #expect(await exec.base.deletes.isEmpty)
        #expect(try await r.tasks.fetch(id: "a") != nil)
        #expect(await exec.base.holds("rec1"))
    }
}
