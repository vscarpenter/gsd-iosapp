import Testing
import Foundation
import GSDModel
import GSDStore
@testable import GSDSync
@testable import GSDWire

/// TaskStore writes a task's queue row before its task row (Fix E). A push that runs in that window
/// sees queued work for a task that isn't live yet. It must still send that work, and nothing may be
/// lost. Import Replace has no such window, because it queues and swaps the task table in one write
/// (`TaskStoreWriteOrderTests.replaceQueuesAndSwapsInOneCall`).
final class PushAfterEnqueue: SyncQueueRepository, @unchecked Sendable {
    let base: GRDBSyncQueueRepository
    var engine: SyncEngine?
    var token = ""
    let fireOn: Int
    private var count = 0
    init(_ base: GRDBSyncQueueRepository, fireOn: Int) { self.base = base; self.fireOn = fireOn }
    func enqueue(_ item: SyncQueueItem) async throws {
        try await base.enqueue(item)
        count += 1
        if count == fireOn, let engine { _ = try await engine.push(token: token, owner: "u1") }
    }
    func pending() async throws -> [SyncQueueItem] { try await base.pending() }
    func update(_ item: SyncQueueItem) async throws { try await base.update(item) }
    func remove(id: String) async throws { try await base.remove(id: id) }
    func enqueueClearingWrites(_ item: SyncQueueItem) async throws { try await base.enqueueClearingWrites(item) }
    func allTaskIds() async throws -> Set<String> { try await base.allTaskIds() }
    func all() async throws -> [SyncQueueItem] { try await base.all() }
}

/// An account that lists what it was sent: creates are stored, nothing else is supported.
actor UniqueServer: RequestExecuting {
    private var records: [String: [String: Any]] = [:]
    private var posts = 0
    func taskIds() -> [String] { records.values.compactMap { $0["task_id"] as? String }.sorted() }
    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? ""
        func reply(_ status: Int, _ body: Data) -> (Data, HTTPURLResponse) {
            (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        if path.hasSuffix("/auth-refresh") { return reply(200, Data(#"{"token":"fresh","record":{"id":"u1","email":"e@x"}}"#.utf8)) }
        if method == "GET" {
            let items = Array(records.values)
            return reply(200, try JSONSerialization.data(withJSONObject: ["page": 1, "perPage": 200, "totalItems": items.count, "totalPages": 1, "items": items]))
        }
        if method == "POST", var body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any] {
            posts += 1; body["id"] = "rec\(posts)"; records["rec\(posts)"] = body
            return reply(200, try JSONSerialization.data(withJSONObject: body))
        }
        return reply(400, Data(#"{"message":"unexpected"}"#.utf8))
    }
}

struct SyncEngineQueueWindowTests {
    private static let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJpZCI6InUxIiwiZXhwIjo5OTk5OTk5OTk5fQ.x"

    @MainActor private func rig(fireOn: Int, server: any RequestExecuting)
        throws -> (store: TaskStore, tasks: GRDBTaskRepository, engine: SyncEngine) {
        let db = try AppDatabase.inMemory()
        let queue = GRDBSyncQueueRepository(db)
        let tasks = GRDBTaskRepository(db)
        let wrapper = PushAfterEnqueue(queue, fireOn: fireOn)
        wrapper.token = Self.jwt
        let store = TaskStore(repository: tasks, smartViewRepository: GRDBSmartViewRepository(db),
                              archiveRepository: GRDBArchiveRepository(db), trashRepository: GRDBTrashRepository(db),
                              defaults: UserDefaults(suiteName: "window.\(UUID().uuidString)")!,
                              clock: { WireDate.parse("2026-11-19T17:45:00.000Z")! }, syncQueue: wrapper)
        let cursor = SyncCursor(defaults: UserDefaults(suiteName: "window.\(UUID().uuidString)")!)
        cursor.advance(maxApplied: Date(timeIntervalSince1970: 1_000)); cursor.markBackfilled()   // a synced device
        let engine = SyncEngine(client: PocketBaseClient(baseURL: "https://guarded.test", executor: server),
                                tasks: tasks, queue: queue, tombstones: GRDBTombstoneRepository(db), cursor: cursor,
                                deviceId: "ios", tokenProvider: { Self.jwt }, rawToken: { Self.jwt },
                                now: { WireDate.parse("2026-11-19T18:00:00.000Z")! }, throttleMs: 0)
        wrapper.engine = engine
        return (store, tasks, engine)
    }

    private func task(_ id: String) -> Task {
        Task(id: id, title: "task \(id)", urgent: false, important: false,
             createdAt: WireDate.parse("2026-11-01T00:00:00.000Z")!, updatedAt: WireDate.parse("2026-11-01T00:00:00.000Z")!)
    }

    @Test("a push between create's queue write and its task write keeps the new task")
    @MainActor func createWindow() async throws {
        let server = UniqueServer()
        let r = try rig(fireOn: 1, server: server)
        try await r.store.create(task("n1"))
        _ = await r.engine.sync(trigger: .periodic)
        #expect(try await r.tasks.fetch(id: "n1") != nil)
        #expect(await server.taskIds() == ["n1"])
    }
}
