import Testing
import Foundation
import GSDModel
import GSDStore
@testable import GSDSync
@testable import GSDWire

/// B-14 (web #538, Android `5da55c0`). A run records the owner it started for and checks it before
/// every write. A sign-out or account switch mid-run ends it: nothing pulled lands, nothing is deleted,
/// no retry is spent, and the cursor stays where the sign-out left it.
struct SyncEngineSessionFenceTests {
    private static func jwt(id: String) -> String {
        let payload = Data(#"{"id":"\#(id)","exp":9999999999}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "h.\(payload).s"
    }
    private static let userOne = jwt(id: "u1")
    private static let userTwo = jwt(id: "u2")
    private static let epoch = "1970-01-01 00:00:00.000Z"
    private static let older = "2026-06-15T09:00:00.000Z"

    /// The token store, as the engine reads it. A nil token means signed out.
    final class Session: @unchecked Sendable {
        var token: String? = userOne
    }

    /// Runs `onRequest` with the number of GETs or the write method, so a test can end the session
    /// exactly where a real sign-out would land.
    final class Executor: RequestExecuting, @unchecked Sendable {
        var items: [String] = []
        var onList: (Int) -> Void = { _ in }
        var onWrite: (String) -> Void = { _ in }
        private(set) var lists = 0
        private(set) var writes: [String] = []
        func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let method = request.httpMethod ?? "GET"
            func response(_ body: String) -> (Data, HTTPURLResponse) {
                (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            if request.url!.path.hasSuffix("/auth-refresh") { return response(#"{"token":"fresh","record":{"id":"u1","email":"e@x"}}"#) }
            if method == "GET" {
                lists += 1
                onList(lists)
                return response(#"{"page":1,"perPage":200,"totalItems":\#(items.count),"totalPages":1,"items":[\#(items.joined(separator: ","))]}"#)
            }
            writes.append(method)
            onWrite(method)
            return response(#"{"id":"rec_new","task_id":"a","title":"t","urgent":false,"important":false}"#)
        }
    }

    /// Ends the session as soon as the first task lands, to prove the check runs per write, not per run.
    final class SigningOutTasks: TaskRepository, @unchecked Sendable {
        let base: GRDBTaskRepository; let session: Session
        init(_ base: GRDBTaskRepository, _ session: Session) { self.base = base; self.session = session }
        func upsert(_ task: Task) async throws { try await base.upsert(task); session.token = nil }
        func fetch(id: String) async throws -> Task? { try await base.fetch(id: id) }
        func fetchAll() async throws -> [Task] { try await base.fetchAll() }
        func delete(id: String) async throws { try await base.delete(id: id); session.token = nil }
        func replaceAll(_ tasks: [Task]) async throws { try await base.replaceAll(tasks) }
        func observeAll() -> AsyncThrowingStream<[Task], Error> { base.observeAll() }
    }

    private func cursor(seeded: Bool = true) -> SyncCursor {
        let cursor = SyncCursor(defaults: UserDefaults(suiteName: "t.\(UUID().uuidString)")!)
        if seeded { cursor.advance(maxApplied: Date(timeIntervalSince1970: 1_000)) }
        return cursor
    }
    private func engine(_ db: AppDatabase, _ exec: Executor, _ session: Session,
                        cursor: SyncCursor? = nil, tasks: (any TaskRepository)? = nil,
                        tokenProvider: (@Sendable () async throws -> String?)? = nil) -> SyncEngine {
        SyncEngine(client: PocketBaseClient(baseURL: "https://api.vinny.io", executor: exec),
                   tasks: tasks ?? GRDBTaskRepository(db), queue: GRDBSyncQueueRepository(db),
                   tombstones: GRDBTombstoneRepository(db), cursor: cursor ?? self.cursor(),
                   deviceId: "dev-A", tokenProvider: tokenProvider ?? { session.token },
                   rawToken: { session.token }, now: { Date(timeIntervalSince1970: 2_000_000_000) },
                   throttleMs: 0, history: GRDBSyncHistoryRepository(db))
    }
    private func task(_ id: String = "a") -> Task {
        Task(id: id, title: "local", urgent: false, important: false,
             createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1))
    }
    private func record(_ id: String = "a") -> String {
        #"{"id":"rec_\#(id)","task_id":"\#(id)","owner":"u1","title":"remote","urgent":false,"important":false,"client_updated_at":"\#(Self.older)","device_id":"dev-B","updated":"\#(Self.older)"}"#
    }
    private func realtime(_ action: String = "update") -> String {
        #"{"action":"\#(action)","record":\#(record())}"#
    }

    // MARK: Pull

    @Test func aSignOutDuringThePullWritesNothingItPulled() async throws {
        let db = try AppDatabase.inMemory(); let session = Session(); let exec = Executor()
        exec.items = [record()]
        exec.onList = { _ in session.token = nil }
        let result = await engine(db, exec, session).sync(trigger: .periodic)
        #expect(try await GRDBTaskRepository(db).fetch(id: "a") == nil)
        #expect(result.notSignedIn && result.error == nil && result.pulled == 0)
    }

    @Test func anAccountSwitchDuringThePullWritesNothingFromTheOldAccount() async throws {
        let db = try AppDatabase.inMemory(); let session = Session(); let exec = Executor()
        exec.items = [record()]
        exec.onList = { _ in session.token = Self.userTwo }
        let result = await engine(db, exec, session).sync(trigger: .periodic)
        #expect(try await GRDBTaskRepository(db).fetch(id: "a") == nil)
        #expect(result.notSignedIn)
    }

    @Test func aSignOutMidPullStopsAtTheNextRecord() async throws {
        let db = try AppDatabase.inMemory(); let session = Session(); let exec = Executor()
        exec.items = [record("a"), record("b")]
        let tasks = SigningOutTasks(GRDBTaskRepository(db), session)
        _ = await engine(db, exec, session, tasks: tasks).sync(trigger: .periodic)
        #expect(try await GRDBTaskRepository(db).fetchAll().count == 1)
    }

    @Test func aSignOutDuringThePullCannotBringBackAnArchivedTask() async throws {
        let db = try AppDatabase.inMemory(); let session = Session(); let exec = Executor()
        try await GRDBArchiveRepository(db).archive(task(), at: Date(timeIntervalSince1970: 2))
        exec.items = [record()]
        exec.onList = { _ in session.token = nil }
        _ = await engine(db, exec, session).sync(trigger: .periodic)
        #expect(try await GRDBArchiveRepository(db).fetchAll().map(\.id) == ["a"])
        #expect(try await GRDBTaskRepository(db).fetch(id: "a") == nil)
    }

    // The next sign-in relies on the cleared cursor to seed and pull everything, so a run that was
    // already in flight must not write it back.
    @Test func aRunStillInFlightCannotUndoTheCursorReset() async throws {
        let db = try AppDatabase.inMemory(); let session = Session(); let exec = Executor()
        let cursor = cursor()
        exec.items = [record()]
        exec.onList = { _ in session.token = nil; cursor.clear() }
        _ = await engine(db, exec, session, cursor: cursor).sync(trigger: .periodic)
        #expect(cursor.load() == nil)
    }

    // The same reset landing late, in reconcile's listing, with nothing left to delete. Only the check
    // right before the cursor write can catch this one.
    @Test func aCursorResetDuringTheLastListingAlsoHolds() async throws {
        let db = try AppDatabase.inMemory(); let session = Session(); let exec = Executor()
        let cursor = cursor()
        exec.items = [record()]
        exec.onList = { call in if call == 3 { session.token = nil; cursor.clear() } }   // pull, push index, reconcile
        let result = await engine(db, exec, session, cursor: cursor).sync(trigger: .periodic)
        #expect(cursor.load() == nil)
        #expect(result.notSignedIn)
    }

    @Test func aSessionEndedBeforeTheSeedQueuesNothing() async throws {
        let db = try AppDatabase.inMemory(); let session = Session()
        try await GRDBTaskRepository(db).upsert(task())
        session.token = nil
        let result = await engine(db, Executor(), session, cursor: cursor(seeded: false),
                                  tokenProvider: { Self.userOne }).sync(trigger: .signIn)
        #expect(result.notSignedIn)
        #expect(try await GRDBSyncQueueRepository(db).all().isEmpty)
    }

    // MARK: Push

    @Test func aSignOutBeforeThePushLeavesTheQueueUntouchedAndSpendsNoRetries() async throws {
        let db = try AppDatabase.inMemory(); let session = Session(); let exec = Executor(); let queue = GRDBSyncQueueRepository(db)
        try await queue.enqueue(SyncQueueItem(id: "q1", taskId: "a", operation: .create, timestamp: 1, payload: task()))
        exec.onList = { call in if call == 2 { session.token = nil } }   // the pull's listing, then push's index
        let result = await engine(db, exec, session).sync(trigger: .periodic)
        let rows = try await queue.all()
        #expect(exec.writes.isEmpty)
        #expect(rows.count == 1 && rows[0].retryCount == 0 && rows[0].status == .pending)
        #expect(result.notSignedIn)
    }

    @Test func aSignOutMidPushStopsBeforeTheNextItem() async throws {
        let db = try AppDatabase.inMemory(); let session = Session(); let exec = Executor(); let queue = GRDBSyncQueueRepository(db)
        try await queue.enqueue(SyncQueueItem(id: "q1", taskId: "a", operation: .create, timestamp: 1, payload: task("a")))
        try await queue.enqueue(SyncQueueItem(id: "q2", taskId: "b", operation: .create, timestamp: 2, payload: task("b")))
        exec.onWrite = { _ in session.token = nil }
        _ = await engine(db, exec, session).pushNow()
        let rows = try await queue.all()
        #expect(exec.writes == ["POST"])                              // the first write had already left
        #expect(rows.map(\.id) == ["q2"] && rows[0].retryCount == 0)
    }

    @Test func aSignOutDuringAQueueDrainReportsNotSignedIn() async throws {
        let db = try AppDatabase.inMemory(); let session = Session(); let exec = Executor(); let queue = GRDBSyncQueueRepository(db)
        try await queue.enqueue(SyncQueueItem(id: "q1", taskId: "a", operation: .create, timestamp: 1, payload: task()))
        exec.onList = { _ in session.token = nil }
        let result = await engine(db, exec, session).pushNow()
        #expect(result.notSignedIn && result.error == nil)
        #expect(exec.writes.isEmpty)
    }

    // MARK: Reconcile

    @Test func aSignOutBeforeReconciliationDeletesNothing() async throws {
        let db = try AppDatabase.inMemory(); let session = Session(); let exec = Executor(); let queue = GRDBSyncQueueRepository(db)
        try await GRDBTaskRepository(db).upsert(task("no-rows"))
        try await GRDBTaskRepository(db).upsert(task("failed-only"))
        try await queue.enqueue(SyncQueueItem(id: "f1", taskId: "failed-only", operation: .create, timestamp: 1, retryCount: 5,
                                              payload: task("failed-only"), status: .failed, lastAttemptAt: 1, failedAt: 1))
        exec.onList = { call in if call == 3 { session.token = nil } }   // pull, push index, reconcile index
        let result = await engine(db, exec, session).sync(trigger: .periodic)
        #expect(try await GRDBTaskRepository(db).fetchAll().count == 2)
        #expect(try await GRDBTrashRepository(db).fetchAll().isEmpty)
        #expect(result.notSignedIn && result.deleted == 0)
    }

    @Test func aSignOutMidReconcileStopsAtTheNextDelete() async throws {
        let db = try AppDatabase.inMemory(); let session = Session(); let exec = Executor()
        try await GRDBTaskRepository(db).upsert(task("a"))
        try await GRDBTaskRepository(db).upsert(task("b"))
        let tasks = SigningOutTasks(GRDBTaskRepository(db), session)
        _ = await engine(db, exec, session, tasks: tasks).sync(trigger: .periodic)
        #expect(try await GRDBTaskRepository(db).fetchAll().count == 1)
    }

    // MARK: Realtime

    @Test func aRealtimeEventAfterSignOutWritesNothing() async throws {
        let db = try AppDatabase.inMemory(); let session = Session()
        session.token = nil
        await engine(db, Executor(), session).applyRealtime(rawData: realtime())
        #expect(try await GRDBTaskRepository(db).fetch(id: "a") == nil)
    }

    // The token read inside the owner check is the last suspension before the write.
    @Test func aSignOutWhileARealtimeEventIsCheckedWritesNothing() async throws {
        let db = try AppDatabase.inMemory(); let session = Session()
        let eng = engine(db, Executor(), session, tokenProvider: { let t = session.token; session.token = nil; return t })
        await eng.applyRealtime(rawData: realtime())
        #expect(try await GRDBTaskRepository(db).fetch(id: "a") == nil)
    }

    @Test func aRealtimeDeleteAfterSignOutDeletesNothing() async throws {
        let db = try AppDatabase.inMemory(); let session = Session()
        try await GRDBTaskRepository(db).upsert(task())
        session.token = nil
        await engine(db, Executor(), session).applyRealtime(rawData: realtime("delete"))
        #expect(try await GRDBTaskRepository(db).fetch(id: "a") != nil)
    }

    @Test func aRealtimeEventCannotBringBackAnArchivedTaskAfterSignOut() async throws {
        let db = try AppDatabase.inMemory(); let session = Session()
        try await GRDBArchiveRepository(db).archive(task(), at: Date(timeIntervalSince1970: 2))
        session.token = nil
        await engine(db, Executor(), session).applyRealtime(rawData: realtime())
        #expect(try await GRDBArchiveRepository(db).fetchAll().map(\.id) == ["a"])
    }

    // An event with no owner field skips the owner check, so the fence is its only protection.
    @Test func anOwnerlessRealtimeEventAfterSignOutWritesNothing() async throws {
        let db = try AppDatabase.inMemory(); let session = Session()
        session.token = nil
        let ownerless = #"{"action":"create","record":{"task_id":"a","title":"remote","client_updated_at":"\#(Self.older)","device_id":"dev-B"}}"#
        await engine(db, Executor(), session).applyRealtime(rawData: ownerless)
        #expect(try await GRDBTaskRepository(db).fetch(id: "a") == nil)
    }

    @Test func aSignOutWhileARealtimeDeleteIsCheckedDeletesNothing() async throws {
        let db = try AppDatabase.inMemory(); let session = Session()
        try await GRDBTaskRepository(db).upsert(task())
        let eng = engine(db, Executor(), session, tokenProvider: { let t = session.token; session.token = nil; return t })
        await eng.applyRealtime(rawData: realtime("delete"))
        #expect(try await GRDBTaskRepository(db).fetch(id: "a") != nil)
    }

    @Test func aSignOutWhileARealtimeEventIsCheckedCannotBringBackAnArchivedTask() async throws {
        let db = try AppDatabase.inMemory(); let session = Session()
        try await GRDBArchiveRepository(db).archive(task(), at: Date(timeIntervalSince1970: 2))
        let eng = engine(db, Executor(), session, tokenProvider: { let t = session.token; session.token = nil; return t })
        await eng.applyRealtime(rawData: realtime())
        #expect(try await GRDBArchiveRepository(db).fetchAll().map(\.id) == ["a"])
    }

    // MARK: Other writes in a run

    @Test func aSessionEndedBeforeTheRetryRevivalLeavesFailedRowsFailed() async throws {
        let db = try AppDatabase.inMemory(); let session = Session(); let queue = GRDBSyncQueueRepository(db)
        try await queue.enqueue(SyncQueueItem(id: "f1", taskId: "a", operation: .create, timestamp: 1, retryCount: 5,
                                              payload: task(), status: .failed, lastAttemptAt: 1, failedAt: 1))
        session.token = nil
        _ = await engine(db, Executor(), session, tokenProvider: { Self.userOne }).sync(trigger: .manual)
        #expect(try await queue.all().first?.status == .failed)
    }

    // An interrupted backfill must run again, under whichever account signs in next.
    @Test func aSignOutDuringTheBackfillLeavesItOwed() async throws {
        let db = try AppDatabase.inMemory(); let session = Session(); let exec = Executor()
        let defaults = UserDefaults(suiteName: "t.\(UUID().uuidString)")!
        let cursor = SyncCursor(defaults: defaults)
        defaults.set("2026-01-01 00:00:00.000Z", forKey: "gsd.sync.lastServerUpdated")   // an older build's cursor, unstamped
        #expect(cursor.needsBackfill())
        exec.onList = { _ in session.token = nil }
        _ = await engine(db, exec, session, cursor: cursor).sync(trigger: .periodic)
        #expect(cursor.needsBackfill())
    }

    // MARK: Unchanged

    @Test func anIntactSessionSyncsNormally() async throws {
        let db = try AppDatabase.inMemory(); let session = Session(); let exec = Executor()
        exec.items = [record()]
        let cursor = cursor()
        let before = cursor.load()
        let result = await engine(db, exec, session, cursor: cursor).sync(trigger: .periodic)
        #expect(result.error == nil && !result.notSignedIn && result.pulled == 1)
        #expect(cursor.load() != before)
    }

    // A refreshed token is a new string for the same account, so the run carries on.
    @Test func aRefreshedTokenForTheSameAccountKeepsTheRunGoing() async throws {
        let db = try AppDatabase.inMemory(); let session = Session(); let exec = Executor()
        exec.items = [record()]
        exec.onList = { _ in session.token = Self.jwt(id: "u1") + "refreshed" }
        let result = await engine(db, exec, session).sync(trigger: .periodic)
        #expect(result.pulled == 1 && !result.notSignedIn)
    }
}
