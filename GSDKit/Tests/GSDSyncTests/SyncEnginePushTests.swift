import Testing
import Foundation
import GSDModel
import GSDStore
@testable import GSDSync
@testable import GSDWire

struct SyncEnginePushTests {
    final class StubExecutor: RequestExecuting, @unchecked Sendable {
        func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            if request.url!.path.hasSuffix("/auth-refresh") {   // the push confirms the account before acting on an unlisted task
                return (Data(#"{"token":"fresh","record":{"id":"u1","email":"e@x"}}"#.utf8),
                        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            return (Data(#"{"page":1,"perPage":200,"totalItems":0,"totalPages":1,"items":[]}"#.utf8),
             HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }
    func makeEngine(tasks: GRDBTaskRepository, queue: GRDBSyncQueueRepository,
                    exec: RequestExecuting = StubExecutor(), cursorDefaults: UserDefaults) -> SyncEngine {
        SyncEngine(client: PocketBaseClient(baseURL: "https://api.vinny.io", executor: exec),
                   tasks: tasks, queue: queue,
                   cursor: SyncCursor(defaults: cursorDefaults), deviceId: "dev-A",
                   tokenProvider: { "TOK" }, now: { Date(timeIntervalSince1970: 2_000_000_000) },
                   throttleMs: 0)
    }

    @Test func seedEnqueuesAllLocalActiveTasks() async throws {
        let db = try AppDatabase.inMemory()
        let tasks = GRDBTaskRepository(db); let queue = GRDBSyncQueueRepository(db)
        // a task created while signed-out (predates sync)
        try await tasks.upsert(Task(id: "offline-1", title: "made offline", urgent: false, important: false,
                                    createdAt: Date(timeIntervalSince1970: 1000), updatedAt: Date(timeIntervalSince1970: 1000)))
        let engine = makeEngine(tasks: tasks, queue: queue, cursorDefaults: UserDefaults(suiteName: "t.\(UUID().uuidString)")!)
        try await engine.seedExistingTasks()
        let queued = try await queue.allTaskIds()
        #expect(queued.contains("offline-1"))   // protected from deletion-reconcile + will be pushed
    }

    final class CRUDExecutor: RequestExecuting, @unchecked Sendable {
        var indexJSON = #"{"page":1,"perPage":200,"totalItems":0,"totalPages":1,"items":[]}"#
        var writeStatus = 200
        var deleteStatus: Int?
        /// Behave like the real server after a delete: a PATCH to a removed record is a 404.
        var missingRecords = false
        private(set) var writes: [(method: String, path: String)] = []
        func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            if request.url!.path.hasSuffix("/auth-refresh") {   // the push confirms the account before acting on an unlisted task
                return (Data(#"{"token":"fresh","record":{"id":"u1","email":"e@x"}}"#.utf8),
                        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            let m = request.httpMethod ?? "GET"
            if m == "GET" {   // listTasks (remoteIndex)
                return (Data(indexJSON.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            let guarded = request.url!.path.hasPrefix("/api/gsd/tasks/")   // only the guarded route may PATCH or DELETE
            writes.append((m == "POST" || guarded ? m : "unguarded \(m)", request.url!.path))
            let body = #"{"id":"rec_x","task_id":"a","title":"t","urgent":false,"important":false}"#
            let status = m == "DELETE" ? (deleteStatus ?? writeStatus) : (missingRecords && m == "PATCH" ? 404 : writeStatus)
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }
    private func remoteItem(taskId: String, recordId: String, updated: String) -> String {
        #"{"task_id":"\#(taskId)","id":"\#(recordId)","title":"remote","urgent":false,"important":false,"client_updated_at":"\#(updated)"}"#
    }

    @Test func pushSkipsAndDropsStaleItemWhenRemoteNewer() async throws {   // THE seed-clobber data-loss guard
        let db = try AppDatabase.inMemory(); let tasks = GRDBTaskRepository(db); let queue = GRDBSyncQueueRepository(db)
        let exec = CRUDExecutor()
        exec.indexJSON = #"{"page":1,"perPage":200,"totalItems":1,"totalPages":1,"items":[\#(remoteItem(taskId: "a", recordId: "rec_a", updated: "2026-06-15T09:00:00.000Z"))]}"#
        let stale = Task(id: "a", title: "stale local", urgent: false, important: false,
                         createdAt: Date(timeIntervalSince1970: 1_000_000), updatedAt: Date(timeIntervalSince1970: 1_000_000))  // day 1
        try await queue.enqueue(SyncQueueItem(id: "q1", taskId: "a", operation: .update, timestamp: 9_999_999_999, payload: stale))
        let engine = makeEngine(tasks: tasks, queue: queue, exec: exec, cursorDefaults: UserDefaults(suiteName: "t.\(UUID().uuidString)")!)
        let (pushed, failed) = try await engine.push(token: "TOK", owner: "u1")
        #expect(pushed == 0 && failed == 0)
        #expect(!exec.writes.contains { $0.method == "PATCH" })       // remote(day2) > payload(day1) → NO clobber
        #expect(try await queue.pending().isEmpty)                    // stale item dropped; next pull delivers remote
    }

    @Test func pushCreatesWhenNoRemote() async throws {
        let db = try AppDatabase.inMemory(); let tasks = GRDBTaskRepository(db); let queue = GRDBSyncQueueRepository(db)
        let exec = CRUDExecutor()   // empty remote index
        let t = Task(id: "a", title: "new local", urgent: false, important: false,
                     createdAt: Date(timeIntervalSince1970: 5_000_000), updatedAt: Date(timeIntervalSince1970: 5_000_000))
        try await queue.enqueue(SyncQueueItem(id: "q1", taskId: "a", operation: .create, timestamp: 1, payload: t))
        let (pushed, _) = try await makeEngine(tasks: tasks, queue: queue, exec: exec, cursorDefaults: UserDefaults(suiteName: "t.\(UUID().uuidString)")!).push(token: "TOK", owner: "u1")
        #expect(pushed == 1)
        #expect(exec.writes.contains { $0.method == "POST" })
        #expect(try await queue.pending().isEmpty)
    }

    // `sync()` derives `owner` from the JWT (unlike `push(token:owner:)`), so these need a real one.
    private static let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJpZCI6InUxIiwiZXhwIjo5OTk5OTk5OTk5fQ.x"
    private func makeSyncEngine(tasks: GRDBTaskRepository, queue: GRDBSyncQueueRepository,
                                exec: RequestExecuting) -> SyncEngine {
        SyncEngine(client: PocketBaseClient(baseURL: "https://api.vinny.io", executor: exec),
                   tasks: tasks, queue: queue,
                   cursor: SyncCursor(defaults: UserDefaults(suiteName: "t.\(UUID().uuidString)")!),
                   deviceId: "dev-A", tokenProvider: { Self.jwt },
                   now: { Date(timeIntervalSince1970: 2_000_000_000) }, throttleMs: 0)
    }

    @Test func manualSyncRevivesFailedItems() async throws {   // §7.7: "tap Sync Now to retry" must be true
        let db = try AppDatabase.inMemory(); let tasks = GRDBTaskRepository(db); let queue = GRDBSyncQueueRepository(db)
        let t = Task(id: "a", title: "x", urgent: false, important: false,
                     createdAt: Date(timeIntervalSince1970: 5_000_000), updatedAt: Date(timeIntervalSince1970: 5_000_000))
        try await queue.enqueue(SyncQueueItem(id: "q1", taskId: "a", operation: .create, timestamp: 1,
                                              retryCount: 5, payload: t, status: .failed,
                                              lastAttemptAt: 1, failedAt: 1))
        let engine = makeSyncEngine(tasks: tasks, queue: queue, exec: CRUDExecutor())   // remote healthy again
        let result = await engine.sync(trigger: .manual)
        #expect(result.pushed == 1)                  // revived + drained
        #expect(try await queue.all().isEmpty)
    }

    @Test func periodicSyncLeavesFailedItemsTerminal() async throws {   // only an explicit retry revives
        let db = try AppDatabase.inMemory(); let tasks = GRDBTaskRepository(db); let queue = GRDBSyncQueueRepository(db)
        let t = Task(id: "a", title: "x", urgent: false, important: false,
                     createdAt: Date(timeIntervalSince1970: 5_000_000), updatedAt: Date(timeIntervalSince1970: 5_000_000))
        try await queue.enqueue(SyncQueueItem(id: "q1", taskId: "a", operation: .create, timestamp: 1,
                                              retryCount: 5, payload: t, status: .failed,
                                              lastAttemptAt: 1, failedAt: 1))
        let engine = makeSyncEngine(tasks: tasks, queue: queue, exec: CRUDExecutor())
        let result = await engine.sync(trigger: .periodic)
        #expect(result.pushed == 0)
        let all = try await queue.all()
        #expect(all.count == 1 && all[0].status == .failed)
    }

    @Test func backgroundSyncPushesPendingItems() async throws {   // a share-captured task reaches the server before the app is next opened
        let db = try AppDatabase.inMemory(); let tasks = GRDBTaskRepository(db); let queue = GRDBSyncQueueRepository(db)
        let t = Task(id: "a", title: "shared from Safari", urgent: false, important: false,
                     createdAt: Date(timeIntervalSince1970: 5_000_000), updatedAt: Date(timeIntervalSince1970: 5_000_000))
        try await queue.enqueue(SyncQueueItem(id: "q1", taskId: "a", operation: .create, timestamp: 1, payload: t))
        let exec = CRUDExecutor()
        let engine = makeSyncEngine(tasks: tasks, queue: queue, exec: exec)
        let result = await engine.sync(trigger: .background)
        #expect(result.pushed == 1)
        #expect(exec.writes.map { $0.method } == ["POST"])
        #expect(try await queue.all().isEmpty)
    }

    @Test func backgroundSyncLeavesFailedItemsTerminal() async throws {   // a background loop must not hammer a rejecting server
        let db = try AppDatabase.inMemory(); let tasks = GRDBTaskRepository(db); let queue = GRDBSyncQueueRepository(db)
        let t = Task(id: "a", title: "x", urgent: false, important: false,
                     createdAt: Date(timeIntervalSince1970: 5_000_000), updatedAt: Date(timeIntervalSince1970: 5_000_000))
        try await queue.enqueue(SyncQueueItem(id: "q1", taskId: "a", operation: .create, timestamp: 1,
                                              retryCount: 5, payload: t, status: .failed,
                                              lastAttemptAt: 1, failedAt: 1))
        let engine = makeSyncEngine(tasks: tasks, queue: queue, exec: CRUDExecutor())
        let result = await engine.sync(trigger: .background)
        #expect(result.pushed == 0)
        let all = try await queue.all()
        #expect(all.count == 1 && all[0].status == .failed)
    }

    @Test func foregroundSyncRevivesFailedItems() async throws {   // reopening the app retries failed edits
        let db = try AppDatabase.inMemory(); let tasks = GRDBTaskRepository(db); let queue = GRDBSyncQueueRepository(db)
        let t = Task(id: "a", title: "x", urgent: false, important: false,
                     createdAt: Date(timeIntervalSince1970: 5_000_000), updatedAt: Date(timeIntervalSince1970: 5_000_000))
        try await queue.enqueue(SyncQueueItem(id: "q1", taskId: "a", operation: .create, timestamp: 1,
                                              retryCount: 5, payload: t, status: .failed,
                                              lastAttemptAt: 1, failedAt: 1))
        let engine = makeSyncEngine(tasks: tasks, queue: queue, exec: CRUDExecutor())   // remote healthy again
        let result = await engine.sync(trigger: .foreground)
        #expect(result.pushed == 1)                  // revived + drained on app reopen
        #expect(try await queue.all().isEmpty)
    }

    @Test func launchSyncRevivesFailedItems() async throws {   // cold start retries failed edits from a prior session
        let db = try AppDatabase.inMemory(); let tasks = GRDBTaskRepository(db); let queue = GRDBSyncQueueRepository(db)
        let t = Task(id: "a", title: "x", urgent: false, important: false,
                     createdAt: Date(timeIntervalSince1970: 5_000_000), updatedAt: Date(timeIntervalSince1970: 5_000_000))
        try await queue.enqueue(SyncQueueItem(id: "q1", taskId: "a", operation: .create, timestamp: 1,
                                              retryCount: 5, payload: t, status: .failed,
                                              lastAttemptAt: 1, failedAt: 1))
        let engine = makeSyncEngine(tasks: tasks, queue: queue, exec: CRUDExecutor())
        let result = await engine.sync(trigger: .launch)
        #expect(result.pushed == 1)
        #expect(try await queue.all().isEmpty)
    }

    // B-45: the delete removed rec_a, so the create that follows it in the same run must POST.
    // A PATCH would hit the deleted record, 404, and spend a retry on a healthy item.
    @Test func createAfterSameRunDeleteRecreatesTheRecord() async throws {
        let db = try AppDatabase.inMemory(); let tasks = GRDBTaskRepository(db); let queue = GRDBSyncQueueRepository(db)
        let exec = CRUDExecutor()
        exec.indexJSON = #"{"page":1,"perPage":200,"totalItems":1,"totalPages":1,"items":[\#(remoteItem(taskId: "a", recordId: "rec_a", updated: "2020-01-01T00:00:00.000Z"))]}"#
        exec.missingRecords = true
        let t = Task(id: "a", title: "restored", urgent: false, important: false,
                     createdAt: Date(timeIntervalSince1970: 1_900_000_000), updatedAt: Date(timeIntervalSince1970: 1_900_000_000))
        try await queue.enqueue(SyncQueueItem(id: "q1", taskId: "a", operation: .delete, timestamp: 1_900_000_000_000, payload: nil))
        try await queue.enqueue(SyncQueueItem(id: "q2", taskId: "a", operation: .create, timestamp: 1_900_000_000_001, payload: t))
        let engine = makeEngine(tasks: tasks, queue: queue, exec: exec, cursorDefaults: UserDefaults(suiteName: "t.\(UUID().uuidString)")!)
        let (pushed, failed) = try await engine.push(token: "TOK", owner: "u1")
        #expect(exec.writes.map { $0.method } == ["DELETE", "POST"])
        #expect(pushed == 2 && failed == 0)
        #expect(try await queue.all().isEmpty)
    }

    // The other side of B-45: a delete the server refused leaves the record in place, so a later
    // item for the task must keep targeting it. A POST here would duplicate the task remotely.
    @Test func failedDeleteKeepsTheRecordInTheIndex() async throws {
        let db = try AppDatabase.inMemory(); let tasks = GRDBTaskRepository(db); let queue = GRDBSyncQueueRepository(db)
        let exec = CRUDExecutor()
        exec.indexJSON = #"{"page":1,"perPage":200,"totalItems":1,"totalPages":1,"items":[\#(remoteItem(taskId: "a", recordId: "rec_a", updated: "2020-01-01T00:00:00.000Z"))]}"#
        exec.deleteStatus = 500
        let t = Task(id: "a", title: "restored", urgent: false, important: false,
                     createdAt: Date(timeIntervalSince1970: 1_900_000_000), updatedAt: Date(timeIntervalSince1970: 1_900_000_000))
        try await queue.enqueue(SyncQueueItem(id: "q1", taskId: "a", operation: .delete, timestamp: 1_900_000_000_000, payload: nil))
        try await queue.enqueue(SyncQueueItem(id: "q2", taskId: "a", operation: .create, timestamp: 1_900_000_000_001, payload: t))
        let engine = makeEngine(tasks: tasks, queue: queue, exec: exec, cursorDefaults: UserDefaults(suiteName: "t.\(UUID().uuidString)")!)
        let (pushed, failed) = try await engine.push(token: "TOK", owner: "u1")
        #expect(exec.writes.map { $0.method } == ["DELETE", "PATCH"])
        #expect(pushed == 1 && failed == 1)
    }

    @Test func pushFailureBumpsRetryCountAndKeepsPending() async throws {
        let db = try AppDatabase.inMemory(); let tasks = GRDBTaskRepository(db); let queue = GRDBSyncQueueRepository(db)
        let exec = CRUDExecutor(); exec.writeStatus = 500   // server error
        let t = Task(id: "a", title: "x", urgent: false, important: false,
                     createdAt: Date(timeIntervalSince1970: 5_000_000), updatedAt: Date(timeIntervalSince1970: 5_000_000))
        try await queue.enqueue(SyncQueueItem(id: "q1", taskId: "a", operation: .create, timestamp: 1, payload: t))
        let (pushed, failed) = try await makeEngine(tasks: tasks, queue: queue, exec: exec, cursorDefaults: UserDefaults(suiteName: "t.\(UUID().uuidString)")!).push(token: "TOK", owner: "u1")
        #expect(pushed == 0 && failed == 1)
        let pending = try await queue.pending()
        #expect(pending.count == 1 && pending[0].retryCount == 1)   // kept, retryCount bumped (across-sync retry)
    }

    /// Archives `x` through the real store when the seed makes its first write, which is for another task.
    /// So the archive lands after the seed's snapshot and before `x`'s own write.
    final class ArchiveOnFirstSeedWrite: SyncQueueRepository, @unchecked Sendable {
        let base: GRDBSyncQueueRepository
        var archiveX: (@Sendable () async throws -> Void)?
        private(set) var firstWriteTaskId: String?
        init(_ base: GRDBSyncQueueRepository) { self.base = base }
        private func firstWrite(_ item: SyncQueueItem) async throws {
            guard firstWriteTaskId == nil else { return }
            firstWriteTaskId = item.taskId
            try await archiveX?()
        }
        func enqueue(_ item: SyncQueueItem) async throws { try await firstWrite(item); try await base.enqueue(item) }
        func enqueueIfLive(_ item: SyncQueueItem) async throws -> Bool {
            try await firstWrite(item); return try await base.enqueueIfLive(item)
        }
        func enqueueClearingWrites(_ item: SyncQueueItem) async throws { try await base.enqueueClearingWrites(item) }
        func pending() async throws -> [SyncQueueItem] { try await base.pending() }
        func update(_ item: SyncQueueItem) async throws { try await base.update(item) }
        func remove(id: String) async throws { try await base.remove(id: id) }
        func allTaskIds() async throws -> Set<String> { try await base.allTaskIds() }
        func all() async throws -> [SyncQueueItem] { try await base.all() }
    }

    private final class Clock: @unchecked Sendable { var date: Date; init(_ d: Date) { date = d } }

    @Test("M1: the seed skips a task archived after its snapshot")
    @MainActor func seedSkipsATaskArchivedAfterItsSnapshot() async throws {
        let listed = "2026-11-19T17:00:00.000Z"
        let clock = Clock(WireDate.parse("2026-11-19T18:00:00.000Z")!)
        let db = try AppDatabase.inMemory()
        let tasks = GRDBTaskRepository(db)
        let base = GRDBSyncQueueRepository(db)
        let queue = ArchiveOnFirstSeedWrite(base)
        let store = TaskStore(repository: tasks, smartViewRepository: GRDBSmartViewRepository(db),
                              archiveRepository: GRDBArchiveRepository(db), trashRepository: GRDBTrashRepository(db),
                              defaults: UserDefaults(suiteName: "seed.\(UUID().uuidString)")!,
                              clock: { clock.date }, syncQueue: queue)
        let created = WireDate.parse("2026-11-01T00:00:00.000Z")!
        // `a` is newer, so the seed reads it first and writes it first.
        let x = Task(id: "x", title: "x", urgent: false, important: false, createdAt: created, updatedAt: WireDate.parse(listed)!)
        let a = Task(id: "a", title: "a", urgent: false, important: false, createdAt: created,
                     updatedAt: WireDate.parse("2026-11-19T17:30:00.000Z")!)
        try await tasks.upsert(x); try await tasks.upsert(a)
        queue.archiveX = { try await store.archive(x); clock.date = clock.date.addingTimeInterval(1) }
        let exec = InFlightExecutor(GuardedServer(), method: "NONE", failInstead: false)
        await exec.base.put(recordId: "recX", taskId: "x", version: listed)
        let token = Self.jwt("u1")
        let cursor = SyncCursor(defaults: UserDefaults(suiteName: "seed.\(UUID().uuidString)")!)
        let engine = SyncEngine(client: PocketBaseClient(baseURL: "https://guarded.test", executor: exec),
                                tasks: tasks, queue: queue, tombstones: GRDBTombstoneRepository(db), cursor: cursor,
                                deviceId: "ios", tokenProvider: { token }, rawToken: { token },
                                now: { clock.date }, throttleMs: 0)

        try await engine.seedExistingTasks()

        #expect(queue.firstWriteTaskId == "a")           // the archive really landed before x's own write
        let rows = try await base.all().filter { $0.taskId == "x" }
        #expect(rows.map(\.operation) == [.delete])
        _ = try await engine.push(token: token, owner: "u1")
        let server = exec.base
        #expect(await server.deletes.map(\.recordId) == ["recX"])
        #expect(await server.patches.isEmpty)
        #expect(await server.collectionWrites.count == 1)   // only `a`, which the server doesn't list yet
        #expect(await server.title(of: "rec_new") == "a")   // a POST stores its record as rec_new
    }

    private static func jwt(_ id: String) -> String {
        let payload = Data(#"{"id":"\#(id)","exp":9999999999}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "h.\(payload).s"
    }
}
