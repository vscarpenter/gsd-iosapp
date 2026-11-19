import Testing
import Foundation
import GSDModel
import GSDStore
@testable import GSDSync
@testable import GSDWire

/// Wraps `GuardedServer`. Before the first write of `method` reaches the server, runs `hook`: the
/// user's archive or Trash, made while the push is in flight. `failInstead` answers that write with
/// a 500 without forwarding it.
final class InFlightExecutor: RequestExecuting, @unchecked Sendable {
    let base: GuardedServer
    let method: String
    let failInstead: Bool
    var hook: (@Sendable () async throws -> Void)?
    init(_ base: GuardedServer, method: String, failInstead: Bool) { self.base = base; self.method = method; self.failInstead = failInstead }
    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if request.httpMethod == method, !(request.url?.path ?? "").hasSuffix("/auth-refresh"), let h = hook {
            hook = nil
            try await h()
            if failInstead {
                return (Data(#"{"message":"boom"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
            }
        }
        return try await base.execute(request)
    }
}

/// A push reads its queue once. A task archived or trashed while its write is in flight has its queued
/// writes removed, and a write that then fails must not put the removed row back.
struct SyncEngineInFlightRemovalTests {
    private final class Clock: @unchecked Sendable { var date: Date; init(_ d: Date) { date = d } }
    private static let now = WireDate.parse("2026-11-19T18:00:00.000Z")!

    @MainActor private func rig(_ exec: InFlightExecutor, clock: Clock)
        throws -> (store: TaskStore, tasks: GRDBTaskRepository, queue: GRDBSyncQueueRepository, engine: SyncEngine) {
        let db = try AppDatabase.inMemory()
        let queue = GRDBSyncQueueRepository(db)
        let tasks = GRDBTaskRepository(db)
        let store = TaskStore(repository: tasks, smartViewRepository: GRDBSmartViewRepository(db),
                              archiveRepository: GRDBArchiveRepository(db), trashRepository: GRDBTrashRepository(db),
                              defaults: UserDefaults(suiteName: "inflight.\(UUID().uuidString)")!,
                              clock: { WireDate.parse("2026-11-19T17:45:00.000Z")! }, syncQueue: queue)
        let engine = SyncEngine(client: PocketBaseClient(baseURL: "https://guarded.test", executor: exec),
                                tasks: tasks, queue: queue,
                                cursor: SyncCursor(defaults: UserDefaults(suiteName: "inflight.\(UUID().uuidString)")!),
                                deviceId: "ios", tokenProvider: { "TOK" }, now: { clock.date }, throttleMs: 0)
        return (store, tasks, queue, engine)
    }

    private func task(_ id: String, at stamp: String) -> Task {
        Task(id: id, title: "t \(id)", urgent: false, important: false,
             createdAt: WireDate.parse("2026-11-01T00:00:00.000Z")!, updatedAt: WireDate.parse(stamp)!)
    }

    @Test("Trash while the task's create is in flight, then the create fails: the task is never POSTed back")
    @MainActor func trashDuringFailingCreate() async throws {
        let server = GuardedServer()
        let exec = InFlightExecutor(server, method: "POST", failInstead: true)
        let clock = Clock(Self.now)
        let r = try rig(exec, clock: clock)
        try await r.store.create(task("n1", at: "2026-11-19T17:00:00.000Z"))
        let created = try #require(try await r.store.fetchTask(id: "n1"))
        exec.hook = { try await r.store.delete(created) }
        _ = try await r.engine.push(token: "TOK", owner: "u1")
        #expect(try await r.queue.all().map(\.operation) == [.delete])   // the failed create was not re-queued
        _ = try await r.engine.push(token: "TOK", owner: "u1")
        clock.date = Self.now.addingTimeInterval(600)
        _ = try await r.engine.push(token: "TOK", owner: "u1")
        #expect(await server.holds("rec_new") == false)
    }

    @Test("Archive while the bumped PATCH is in flight and its 204 is lost: the task is never POSTed back")
    @MainActor func archiveDuringLostPatch() async throws {
        let server = GuardedServer()
        await server.put(recordId: "rec1", taskId: "a", version: "2026-11-19T17:00:00.000Z")
        await server.loseResponseOfNextPatch()
        let exec = InFlightExecutor(server, method: "PATCH", failInstead: false)
        let clock = Clock(Self.now)
        let r = try rig(exec, clock: clock)
        let row = task("a", at: "2026-11-19T17:00:00.000Z")
        try await r.tasks.upsert(row)
        try await r.queue.enqueue(SyncQueueItem(id: "q1", taskId: "a", operation: .update,
            timestamp: Int(row.updatedAt.timeIntervalSince1970 * 1000), payload: row))
        exec.hook = { try await r.store.archive(row) }
        _ = try await r.engine.push(token: "TOK", owner: "u1")
        #expect(try await r.queue.all().map(\.operation) == [.delete])
        _ = try await r.engine.push(token: "TOK", owner: "u1")
        #expect(await server.holds("rec1") == false)
        clock.date = Self.now.addingTimeInterval(600)
        _ = try await r.engine.push(token: "TOK", owner: "u1")
        #expect(await server.holds("rec_new") == false)
        #expect(await server.collectionWrites.isEmpty)
    }
}
