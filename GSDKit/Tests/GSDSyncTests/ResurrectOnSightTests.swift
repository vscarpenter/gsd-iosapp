import Foundation
import Testing
import GRDB
import GSDModel
import GSDStore
@testable import GSDSync
@testable import GSDWire

/// A PocketBase account with several records. Lists by the `updated` filter, merges a PATCH, records
/// each DELETE, and answers `auth-refresh` with the owner. A dead session lists nothing and fails
/// `auth-refresh`, like a token the server rejects. An incomplete listing promises one record more
/// than it lists.
actor AccountServer: RequestExecuting {
    private var records: [String: [String: Any]] = [:]   // task_id → record
    private(set) var deletedTaskIds: [String] = []
    private(set) var writtenTaskIds: [String] = []
    /// Each PATCH's task and the title it carried.
    private(set) var patches: [(taskId: String, title: String?)] = []
    private(set) var listings = 0
    private var sessionDead = false
    private var anotherAccount = false
    private var incomplete = false
    private var listingFails = false
    private var onListing: (@Sendable () -> Void)?

    func add(_ taskId: String, title: String = "Call the venue", clientUpdatedAt: String = "2026-11-01T10:00:00.000Z",
             dueDate: String = "") {
        records[taskId] = ["id": "rec_\(taskId)", "task_id": taskId, "owner": "u1", "title": title, "description": "",
                           "due_date": dueDate,
                           "urgent": true, "important": true, "client_created_at": "2026-10-01T10:00:00.000Z",
                           "client_updated_at": clientUpdatedAt, "updated": "2026-11-01 10:00:01.000Z", "device_id": "web"]
    }

    /// A record this build can't read (a wrong-typed field) but can still identify: the ordinary pull
    /// skips it, push and reconcile index it, and the step's complete listing throws on it.
    func addUnreadable(_ taskId: String) {
        add(taskId)
        records[taskId]?["title"] = 42
    }

    func killSession() { sessionDead = true }
    /// `auth-refresh` confirms a different account than the token's owner.
    func answerAsAnotherAccount() { anotherAccount = true }
    func listIncompletely() { incomplete = true }
    func failListings(_ fail: Bool) { listingFails = fail }
    func has(_ taskId: String) -> Bool { records[taskId] != nil }
    /// The title the account would list for `taskId`.
    func title(of taskId: String) -> String? { records[taskId]?["title"] as? String }
    /// Runs once, the next time the account is listed: something else happening while a run awaits.
    func whenListed(_ hook: @escaping @Sendable () -> Void) { onListing = hook }

    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        if url.path.hasSuffix("/auth-refresh") {
            if sessionDead { return (Data(#"{"message":"The request requires valid record authorization token."}"#.utf8), response(url, 401)) }
            let id = anotherAccount ? "u2" : "u1"
            return (Data(#"{"token":"fresh","record":{"id":"\#(id)","email":"\#(id)@example.com"}}"#.utf8), response(url, 200))
        }
        let method = request.httpMethod ?? "GET"
        if sessionDead, method != "GET" {   // the server rejects every write from a dead token
            return (Data(#"{"message":"The request requires valid record authorization token."}"#.utf8), response(url, 401))
        }
        switch method {
        case "GET": return try list(request, url: url)
        case "DELETE":
            if let taskId = records.first(where: { $0.value["id"] as? String == url.lastPathComponent })?.key {
                records[taskId] = nil
                deletedTaskIds.append(taskId)
            }
            return (Data(), response(url, 204))
        default:   // POST creates, PATCH merges
            var body = try #require(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
            let guarded = url.path.hasPrefix("/api/gsd/tasks/")   // the guarded route wraps the record in `data`
            if guarded { body = try #require(body["data"] as? [String: Any]) }
            let taskId = try #require(body["task_id"] as? String)
            var record = records[taskId] ?? ["id": "rec_\(taskId)", "updated": "2026-11-07 12:00:00.000Z"]
            record.merge(body.filter { $0.key != "id" }) { _, new in new }
            records[taskId] = record
            writtenTaskIds.append(taskId)
            if method == "PATCH" { patches.append((taskId, body["title"] as? String)) }
            if guarded { return (Data(), response(url, 204)) }
            return (try JSONSerialization.data(withJSONObject: record), response(url, 200))
        }
    }

    private func list(_ request: URLRequest, url: URL) throws -> (Data, HTTPURLResponse) {
        listings += 1
        onListing?(); onListing = nil
        if listingFails { return (Data(#"{"message":"unavailable"}"#.utf8), response(url, 503)) }
        let items = sessionDead ? [] : records.keys.sorted().compactMap { records[$0] }.filter { listed($0, by: request) }
        let page: [String: Any] = ["page": 1, "perPage": 200, "totalItems": items.count + (incomplete ? 1 : 0),
                                   "totalPages": 1, "items": items]
        return (try JSONSerialization.data(withJSONObject: page), response(url, 200))
    }

    private func listed(_ record: [String: Any], by request: URLRequest) -> Bool {
        guard let url = request.url,
              let filter = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                  .queryItems?.first(where: { $0.name == "filter" })?.value else { return true }
        let quoted = filter.split(separator: "\"")
        guard quoted.count >= 2, let since = WireDate.parse(String(quoted[1])),
              let updated = WireDate.parse(record["updated"] as? String ?? "") else { return true }
        return updated >= since
    }

    private func response(_ url: URL, _ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
    }
}

/// Resurrect on sight (`gsd-taskmanager/tasks/spec-resurrect-on-sight.md`, iOS section 5). Names
/// match the spec's section 6 table, so the three clients' suites read side by side.
@MainActor
struct ResurrectOnSightTests {
    nonisolated private static let token = "eyJhbGciOiJIUzI1NiJ9.eyJpZCI6InUxIiwiZXhwIjo5OTk5OTk5OTk5fQ.x"
    nonisolated private static let now = WireDate.parse("2026-11-07T12:00:00.000Z")!

    private enum Device {
        /// Signed out on this build: no cursor, and the contract version kept.
        case signedOut
        /// Signed in, after a completed sync.
        case signedIn
    }

    /// The store's clock. A test moves it to edit a task earlier than it trashes it.
    private final class Clock: @unchecked Sendable { var date: Date; init(_ d: Date) { date = d } }

    /// The real Trash and archive, plus a hook that runs once, right after the sync reads a Trash row:
    /// the user acting on the task while the bring-back still awaits its write.
    private final class RacingTombstones: TombstoneRepository, @unchecked Sendable {
        let base: GRDBTombstoneRepository
        var afterBuriedRead: (@MainActor @Sendable () async throws -> Void)?
        init(_ base: GRDBTombstoneRepository) { self.base = base }
        func tombstoneDate(id: String) async throws -> Date? { try await base.tombstoneDate(id: id) }
        func isArchived(id: String) async throws -> Bool { try await base.isArchived(id: id) }
        func resurrect(_ task: Task) async throws { try await base.resurrect(task) }
        func resurrectFromTrash(_ task: Task, queueing item: SyncQueueItem) async throws -> Bool {
            try await base.resurrectFromTrash(task, queueing: item)
        }
        func abandonToTrash(id: String, at deletedAt: Date) async throws -> Bool {
            try await base.abandonToTrash(id: id, at: deletedAt)
        }
        func buriedTask(id: String) async throws -> Task? {
            let buried = try await base.buriedTask(id: id)
            if let act = afterBuriedRead { afterBuriedRead = nil; try await act() }
            return buried
        }
    }

    private struct Stack {
        let server: AccountServer
        let db: AppDatabase
        let repo: GRDBTaskRepository
        let queue: GRDBSyncQueueRepository
        let trash: GRDBTrashRepository
        let archive: GRDBArchiveRepository
        let cursor: SyncCursor
        let engine: SyncEngine
        let store: TaskStore
        let clock: Clock
        let racing: RacingTombstones?

        /// An active row at the server's version, as an earlier sync left it.
        @discardableResult
        func seedActive(_ id: String, title: String = "Call the venue",
                        updatedAt: String = "2026-11-01T10:00:00.000Z") async throws -> Task {
            let task = Task(id: id, title: title, urgent: true, important: true,
                            createdAt: try #require(WireDate.parse("2026-10-01T10:00:00.000Z")),
                            updatedAt: try #require(WireDate.parse(updatedAt)))
            try await repo.upsert(task)
            return task
        }

        /// A Trash row for `id`, as a delete leaves it.
        func seedTrashed(_ id: String) async throws {
            try await trash.trash(try await seedActive(id), at: ResurrectOnSightTests.now)
        }

        func enqueueDelete(_ id: String, payload: Task? = nil, status: SyncQueueItem.Status = .pending) async throws {
            try await queue.enqueue(SyncQueueItem(id: UUID().uuidString, taskId: id, operation: .delete,
                                                  timestamp: Int(ResurrectOnSightTests.now.timeIntervalSince1970 * 1000),
                                                  payload: payload, status: status))
        }

        func isActive(_ id: String) async throws -> Bool { try await repo.fetch(id: id) != nil }
        func isTrashed(_ id: String) async throws -> Bool { try await trash.fetchAll().contains { $0.id == id } }
    }

    private func makeStack(_ device: Device, server: AccountServer = AccountServer(),
                           racing: Bool = false) throws -> Stack {
        let db = try AppDatabase.inMemory()
        let defaults = UserDefaults(suiteName: "resurrect-\(UUID().uuidString)")!
        let cursor = SyncCursor(defaults: defaults)
        cursor.advance(maxApplied: WireDate.parse("2026-11-02T00:00:00.000Z"))
        if device == .signedOut { cursor.clear() }
        let repo = GRDBTaskRepository(db)
        let queue = GRDBSyncQueueRepository(db)
        let trash = GRDBTrashRepository(db)
        let archive = GRDBArchiveRepository(db)
        let racer = racing ? RacingTombstones(GRDBTombstoneRepository(db)) : nil
        let engine = SyncEngine(client: PocketBaseClient(baseURL: "https://resurrect.test", executor: server),
                                tasks: repo, queue: queue, tombstones: racer ?? GRDBTombstoneRepository(db), cursor: cursor,
                                deviceId: "ios", tokenProvider: { Self.token }, rawToken: { Self.token },
                                now: { Self.now }, throttleMs: 0)
        let clock = Clock(Self.now)
        let store = TaskStore(repository: repo, smartViewRepository: GRDBSmartViewRepository(db),
                              archiveRepository: archive, trashRepository: trash, defaults: defaults,
                              clock: { clock.date }, syncQueue: queue)
        return Stack(server: server, db: db, repo: repo, queue: queue, trash: trash, archive: archive,
                     cursor: cursor, engine: engine, store: store, clock: clock, racing: racer)
    }

    // MARK: The step (rules 3 to 5)

    @Test("a remembered delete comes back when the account lists the task")
    func aRememberedDeleteComesBack() async throws {
        let stack = try makeStack(.signedIn)
        await stack.server.add("t1")
        try await stack.seedTrashed("t1")
        stack.cursor.rememberDeletes(["t1"])

        let brought = try await stack.engine.resurrectOnSight(token: Self.token, owner: "u1")

        #expect(brought == 1)
        #expect(try await stack.isActive("t1"))
        #expect(!(try await stack.isTrashed("t1")))
        #expect(stack.cursor.rememberedDeletes().isEmpty)
    }

    @Test("a remembered delete with no server copy keeps its Trash copy and is forgotten")
    func aRememberedDeleteWithNoServerCopy() async throws {
        let stack = try makeStack(.signedIn)
        await stack.server.add("other")
        try await stack.seedTrashed("t1")
        stack.cursor.rememberDeletes(["t1"])

        _ = try await stack.engine.resurrectOnSight(token: Self.token, owner: "u1")

        #expect(try await stack.isTrashed("t1"))
        #expect(stack.cursor.rememberedDeletes().isEmpty)
    }

    @Test("a remembered id active again with a newer local edit keeps the local copy")
    func aRememberedIdWithANewerLocalEdit() async throws {
        let stack = try makeStack(.signedIn)
        await stack.server.add("t1")
        try await stack.seedActive("t1", title: "Call the venue today", updatedAt: "2026-11-05T10:00:00.000Z")
        stack.cursor.rememberDeletes(["t1"])

        _ = try await stack.engine.resurrectOnSight(token: Self.token, owner: "u1")

        #expect(try await stack.repo.fetch(id: "t1")?.title == "Call the venue today")
        #expect(stack.cursor.rememberedDeletes().isEmpty)
    }

    @Test("a dead session forgets no remembered delete")
    func aDeadSessionForgetsNothing() async throws {
        let stack = try makeStack(.signedIn)
        await stack.server.add("t1")
        await stack.server.killSession()
        try await stack.seedTrashed("t1")
        stack.cursor.rememberDeletes(["t1"])

        await #expect(throws: (any Error).self) { try await stack.engine.resurrectOnSight(token: Self.token, owner: "u1") }

        #expect(stack.cursor.rememberedDeletes() == ["t1"])
        #expect(try await stack.isTrashed("t1"))
    }

    @Test("an incomplete listing forgets no remembered delete")
    func anIncompleteListingForgetsNothing() async throws {
        let stack = try makeStack(.signedIn)
        await stack.server.add("t1")
        await stack.server.listIncompletely()
        try await stack.seedTrashed("t1")
        stack.cursor.rememberDeletes(["t1"])

        await #expect(throws: (any Error).self) { try await stack.engine.resurrectOnSight(token: Self.token, owner: "u1") }

        #expect(stack.cursor.rememberedDeletes() == ["t1"])
        #expect(try await stack.isTrashed("t1"))
    }

    /// Restored while signed out, so a create is queued, against a far-future server stamp.
    @Test("a held-off remembered id stays for the next run")
    func aHeldOffRememberedIdStays() async throws {
        let stack = try makeStack(.signedIn)
        await stack.server.add("t1", clientUpdatedAt: "2027-06-01T00:00:00.000Z")
        await stack.server.add("t2")
        try await stack.seedTrashed("t1")
        try await stack.seedTrashed("t2")
        try await stack.store.restoreFromTrash(id: "t1")
        stack.cursor.rememberDeletes(["t1", "t2"])

        _ = try await stack.engine.resurrectOnSight(token: Self.token, owner: "u1")

        #expect(stack.cursor.rememberedDeletes() == ["t1"])
        #expect(try await stack.isActive("t2"))
    }

    /// S-AND's A1: after a run that kept the id, the user restored the task and trashed it again. That
    /// delete is the user's latest act and will push, so the step leaves the Trash row and keeps the id.
    @Test("a remembered id with a pending delete stays in Trash and is kept")
    func aRememberedIdWithAPendingDeleteStaysInTrash() async throws {
        let stack = try makeStack(.signedIn)
        await stack.server.add("t1")
        try await stack.seedTrashed("t1")
        stack.cursor.rememberDeletes(["t1"])
        try await stack.enqueueDelete("t1")

        let brought = try await stack.engine.resurrectOnSight(token: Self.token, owner: "u1")

        #expect(brought == 0)
        #expect(try await stack.isTrashed("t1"))
        #expect(!(try await stack.isActive("t1")))
        #expect(stack.cursor.rememberedDeletes() == ["t1"])
    }

    /// A failed row is re-armed (`requeueFailed`), so a failed delete will still push too.
    @Test("a remembered id with a failed delete stays in Trash and is kept")
    func aRememberedIdWithAFailedDeleteStaysInTrash() async throws {
        let stack = try makeStack(.signedIn)
        await stack.server.add("t1")
        try await stack.seedTrashed("t1")
        stack.cursor.rememberDeletes(["t1"])
        try await stack.enqueueDelete("t1", status: .failed)

        let brought = try await stack.engine.resurrectOnSight(token: Self.token, owner: "u1")

        #expect(brought == 0)
        #expect(try await stack.isTrashed("t1"))
        #expect(stack.cursor.rememberedDeletes() == ["t1"])
    }

    /// S-AND's A2, the Lead's call: an unreadable server copy fails every complete listing. A step
    /// that threw ended the run before its push, so the user's own edits never went up.
    @Test("a step that fails forgets nothing and leaves the sync successful")
    func aStepThatFailsForgetsNothingAndLeavesTheSyncSuccessful() async throws {
        let stack = try makeStack(.signedIn)
        await stack.server.add("t1")
        await stack.server.add("t2")
        await stack.server.addUnreadable("t9")
        try await stack.seedTrashed("t1")
        stack.cursor.rememberDeletes(["t1"])
        try await stack.store.toggleComplete(try await stack.seedActive("t2"))   // the user's own edit

        let result = await stack.engine.sync(trigger: .manual)

        #expect(result.error == nil)
        #expect(result.pushed == 1)
        #expect(stack.cursor.rememberedDeletes() == ["t1"])
        #expect(try await stack.isTrashed("t1"))
    }

    /// The Lead's review of #97: a token the server confirms for another account is no failed step.
    /// The run stops there, because the push has no identity check of its own (only the reconcile
    /// does, and it runs after the push).
    @Test("a step whose identity check fails stops the run before the push")
    func aStepWhoseIdentityCheckFailsStopsTheRunBeforeThePush() async throws {
        let stack = try makeStack(.signedIn)
        await stack.server.add("t1")
        await stack.server.add("t2")
        await stack.server.answerAsAnotherAccount()
        try await stack.seedTrashed("t1")
        stack.cursor.rememberDeletes(["t1"])
        try await stack.store.toggleComplete(try await stack.seedActive("t2"))   // the user's own edit

        let result = await stack.engine.sync(trigger: .manual)

        #expect(result.error != nil)
        #expect(result.pushed == 0)
        #expect(await stack.server.writtenTaskIds.isEmpty)
        #expect(stack.cursor.rememberedDeletes() == ["t1"])
    }

    /// S-AND's second review of #97 (F1): a rejected token lists as an empty account, so the step's
    /// auth-refresh is the first to see it. The run stops there. Otherwise the push would send every
    /// queued write to a dead session and spend a retry on each.
    @Test("a dead session found by the step pushes nothing")
    func aDeadSessionFoundByTheStepPushesNothing() async throws {
        let stack = try makeStack(.signedIn)
        await stack.server.add("t1")
        await stack.server.add("t2")
        try await stack.seedTrashed("t1")
        stack.cursor.rememberDeletes(["t1"])
        try await stack.store.toggleComplete(try await stack.seedActive("t2"))   // the user's own edit
        await stack.server.killSession()

        let result = await stack.engine.sync(trigger: .manual)

        #expect(result.error != nil)
        #expect(result.pushed == 0)
        #expect(await stack.server.writtenTaskIds.isEmpty)
        #expect(try await stack.queue.all().map(\.retryCount) == [0])
        #expect(stack.cursor.rememberedDeletes() == ["t1"])
    }

    /// The Lead's decision on S-AND's review: the server copy merges into the Trash row, as web does,
    /// instead of replacing it, so this device's reminder state and rich time entries survive.
    @Test("a resurrected task keeps this device's reminder state and time-entry notes")
    func aResurrectedTaskKeepsReminderStateAndTimeEntryNotes() async throws {
        let stack = try makeStack(.signedIn)
        let due = "2026-11-10T15:00:00.000Z"
        await stack.server.add("t1", dueDate: due)
        let started = try #require(WireDate.parse("2026-11-01T09:00:00.000Z"))
        let entry = TimeEntry(id: "e1", startedAt: started, endedAt: started.addingTimeInterval(1500),
                              notes: "Left a voicemail")
        var row = try await stack.seedActive("t1")
        row.dueDate = WireDate.parse(due)
        row.timeEntries = [entry]
        row.notificationSent = true
        row.lastNotificationAt = try #require(WireDate.parse("2026-11-06T14:45:00.000Z"))
        row.snoozedUntil = try #require(WireDate.parse("2026-11-10T14:30:00.000Z"))
        try await stack.trash.trash(row, at: Self.now)
        stack.cursor.rememberDeletes(["t1"])

        _ = try await stack.engine.resurrectOnSight(token: Self.token, owner: "u1")

        let back = try #require(try await stack.repo.fetch(id: "t1"))
        #expect(back.timeEntries == [entry])
        #expect(back.notificationSent && back.lastNotificationAt == row.lastNotificationAt)
        #expect(back.snoozedUntil == row.snoozedUntil)
    }

    /// S-AND's note 3, the Lead's fix: the step awaits the listing, so a sign-in can remember another
    /// id meanwhile. Only the ids in the snapshot taken when the step began are forgotten.
    @Test func anIdRememberedWhileTheStepAwaitsIsKept() async throws {
        let stack = try makeStack(.signedIn)
        await stack.server.add("t1")
        try await stack.seedTrashed("t1")
        stack.cursor.rememberDeletes(["t1"])
        let cursor = stack.cursor
        await stack.server.whenListed { cursor.rememberDeletes(["t9"]) }

        _ = try await stack.engine.resurrectOnSight(token: Self.token, owner: "u1")

        #expect(stack.cursor.rememberedDeletes() == ["t9"])
    }

    /// Section 8, reading 2 (owner item 26): trashed, restored, then archived while signed out. The
    /// archive is the user's last act, so it stands. The id is still forgotten.
    @Test("a remembered id with an archive row stays archived")
    func aRememberedIdWithAnArchiveRowStaysArchived() async throws {
        let stack = try makeStack(.signedIn)
        await stack.server.add("t1")
        try await stack.archive.archive(try await stack.seedActive("t1"))
        stack.cursor.rememberDeletes(["t1"])

        _ = try await stack.engine.resurrectOnSight(token: Self.token, owner: "u1")

        #expect(try await stack.archive.fetchAll().contains { $0.id == "t1" })
        #expect(!(try await stack.isActive("t1")))
        #expect(stack.cursor.rememberedDeletes().isEmpty)
    }

    @Test("nothing remembered means no extra listing")
    func nothingRememberedMeansNoExtraListing() async throws {
        let quiet = try makeStack(.signedIn)
        await quiet.server.add("t1")
        _ = await quiet.engine.sync(trigger: .manual)
        let remembering = try makeStack(.signedIn)
        await remembering.server.add("t1")
        remembering.cursor.rememberDeletes(["t9"])
        _ = await remembering.engine.sync(trigger: .manual)

        let baseline = await quiet.server.listings
        #expect(await remembering.server.listings == baseline + 1)
    }

    // MARK: The sign-in moment (rules 1 and 2, section 5)

    @Test("sign-in drops queued deletes and remembers the Trash and Replace ones")
    func signInDropsQueuedDeletes() async throws {
        let stack = try makeStack(.signedOut)
        let archived = try await stack.seedActive("t3")
        try await stack.enqueueDelete("t1")                      // a Trash delete
        try await stack.enqueueDelete("t2")                      // a Replace import's delete
        try await stack.enqueueDelete("t3", payload: archived)   // an archive's delete carries the task
        try await stack.queue.enqueue(SyncQueueItem(id: "edit", taskId: "t4", operation: .update, timestamp: 1,
                                                    payload: try await stack.seedActive("t4")))

        try await stack.engine.dropSignedOutDeletes()

        #expect(try await stack.queue.all().map(\.id) == ["edit"])
        #expect(stack.cursor.rememberedDeletes() == ["t1", "t2"])
    }

    /// SPEC-3 (#680) rule 2: the sign-in drop adds to the remembered ids and never replaces them, so an
    /// id an earlier sign-in remembered, and no run has listed yet, is still there.
    @Test("sign-in keeps the remembered ids")
    func signInKeepsTheRememberedIds() async throws {
        let stack = try makeStack(.signedOut)
        stack.cursor.rememberDeletes(["t0"])
        try await stack.enqueueDelete("t1")

        try await stack.engine.dropSignedOutDeletes()

        #expect(stack.cursor.rememberedDeletes() == ["t0", "t1"])
    }

    @Test("a re-sign-in after a rejected token drops no queued delete")
    func aReSignInAfterARejectedTokenDropsNothing() async throws {
        let stack = try makeStack(.signedIn)                     // a rejected token keeps the cursor
        try await stack.enqueueDelete("t1")

        try await stack.engine.dropSignedOutDeletes()

        #expect(try await stack.queue.all().map(\.taskId) == ["t1"])
        #expect(stack.cursor.rememberedDeletes().isEmpty)
    }

    /// The edge section 5 accepts: the first sync never completed, so no cursor was ever written.
    @Test("a token rejected before the first sync completes counts as signed out")
    func aTokenRejectedBeforeTheFirstSyncCountsAsSignedOut() async throws {
        let stack = try makeStack(.signedOut)
        try await stack.enqueueDelete("t1")

        try await stack.engine.dropSignedOutDeletes()

        #expect(try await stack.queue.all().isEmpty)
        #expect(stack.cursor.rememberedDeletes() == ["t1"])
    }

    /// The Lead's decision on S-AND's note 2: nothing drains the queue before the sign-in drop. Here a
    /// mutation's debounced push is the first engine run after sign-in, ahead of the sign-in sync.
    @Test("a mutation-triggered push right after sign-in sends no signed-out delete")
    func aMutationPushRightAfterSignInSendsNoSignedOutDelete() async throws {
        let stack = try makeStack(.signedOut)
        await stack.server.add("t1")
        try await stack.store.delete(try await stack.seedActive("t1"))   // signed out

        await stack.engine.beginSignIn()
        _ = await stack.engine.pushNow()

        #expect(await stack.server.deletedTaskIds.isEmpty)
        #expect(stack.cursor.rememberedDeletes() == ["t1"])
        _ = await stack.engine.sync(trigger: .signIn)
        #expect(try await stack.isActive("t1"))
    }

    @Test("a failed first sync doesn't drop a delete made while signed in")
    func aFailedFirstSyncDoesNotDropASignedInDelete() async throws {
        let stack = try makeStack(.signedOut)
        await stack.server.add("t5")
        let task = try await stack.seedActive("t5")
        await stack.engine.beginSignIn()
        await stack.server.failListings(true)
        _ = await stack.engine.sync(trigger: .signIn)            // drops (nothing queued), then fails: cursor stays nil
        await stack.server.failListings(false)
        try await stack.store.delete(task)                      // signed in now

        _ = await stack.engine.sync(trigger: .launch)

        #expect(await stack.server.deletedTaskIds == ["t5"])
        #expect(stack.cursor.rememberedDeletes().isEmpty)
    }

    // MARK: Journeys

    @Test("a task trashed signed out comes back out of Trash after the next sign-in")
    func aTaskTrashedSignedOutComesBack() async throws {
        let stack = try makeStack(.signedOut)
        await stack.server.add("t1")
        try await stack.store.delete(try await stack.seedActive("t1"))

        await stack.engine.beginSignIn()
        let result = await stack.engine.sync(trigger: .signIn)

        #expect(result.error == nil)
        #expect(try await stack.isActive("t1"))
        #expect(!(try await stack.isTrashed("t1")))
        #expect(await stack.server.has("t1"))
        #expect(await stack.server.deletedTaskIds.isEmpty)
        #expect(stack.cursor.rememberedDeletes().isEmpty)
    }

    @Test("a Replace import made signed out deletes nothing on the server after the next sign-in")
    func aReplaceImportMadeSignedOutDeletesNothing() async throws {
        let stack = try makeStack(.signedOut)
        await stack.server.add("t1")
        await stack.server.add("t2")
        try await stack.seedActive("t1")
        try await stack.seedActive("t2")
        let backup = TaskExport(tasks: [Task(id: "t3", title: "Imported", urgent: false, important: true,
                                             createdAt: Self.now, updatedAt: Self.now)], exportedAt: Self.now)
        try await stack.store.importTasks(try TaskExport.encode(backup), mode: .replace)

        await stack.engine.beginSignIn()
        _ = await stack.engine.sync(trigger: .signIn)

        #expect(await stack.server.deletedTaskIds.isEmpty)
        #expect(await stack.server.has("t1"))
        #expect(await stack.server.has("t2"))
        #expect(stack.cursor.rememberedDeletes().isEmpty)
    }

    @Test("an archive made while signed out stays archived and isn't remembered")
    func anArchiveMadeSignedOutStaysArchived() async throws {
        let stack = try makeStack(.signedOut)
        await stack.server.add("t3")
        try await stack.store.archive(try await stack.seedActive("t3"))

        await stack.engine.beginSignIn()
        _ = await stack.engine.sync(trigger: .signIn)

        #expect(stack.cursor.rememberedDeletes().isEmpty)
        #expect(try await stack.archive.fetchAll().contains { $0.id == "t3" })
        #expect(!(try await stack.isActive("t3")))
        #expect(await stack.server.has("t3"))
        #expect(await stack.server.deletedTaskIds.isEmpty)
    }

    /// S-AND's A1 end to end. Before the fix, the step brought the task back, the push sent the delete,
    /// and the reconcile then removed the active copy with no Trash copy left.
    @Test("a task restored and trashed again while its id is remembered stays in Trash after the next sync")
    func aTaskRestoredAndTrashedAgainStaysInTrash() async throws {
        let stack = try makeStack(.signedIn)
        await stack.server.add("t1")
        try await stack.seedTrashed("t1")
        stack.cursor.rememberDeletes(["t1"])                     // an earlier run failed, so it kept the id
        try await stack.store.restoreFromTrash(id: "t1")
        _ = await stack.engine.pushNow()                         // the restore's create goes up
        try await stack.store.delete(try #require(try await stack.repo.fetch(id: "t1")))

        let result = await stack.engine.sync(trigger: .manual)

        #expect(result.error == nil)
        #expect(try await stack.isTrashed("t1"))
        #expect(!(try await stack.isActive("t1")))
        #expect(await stack.server.deletedTaskIds == ["t1"])
        _ = await stack.engine.sync(trigger: .manual)            // the account no longer lists it
        #expect(stack.cursor.rememberedDeletes().isEmpty)
        #expect(try await stack.isTrashed("t1"))
    }

    @Test("a delete made while signed in still deletes on the server")
    func aDeleteMadeSignedInStillDeletes() async throws {
        let stack = try makeStack(.signedIn)
        await stack.server.add("t1")
        try await stack.store.delete(try await stack.seedActive("t1"))

        _ = await stack.engine.sync(trigger: .manual)

        #expect(await stack.server.deletedTaskIds == ["t1"])
    }

    // MARK: A Trash row newer than the server's copy (R25)

    /// T1, the signed-out edit. Each test sets the server's stamp against it.
    nonisolated private static let editedAt = "2026-11-07T11:00:00.000Z"

    /// While signed out, edit `x`'s title to "new" at `editedAt`, then trash it at `now`. Trash removes
    /// the edit's queued update, so only the Trash row still holds the edit.
    private func editThenTrashSignedOut(_ stack: Stack) async throws {
        var task = try await stack.seedActive("x", title: "old")
        stack.clock.date = try #require(WireDate.parse(Self.editedAt))
        task.title = "new"
        try await stack.store.save(task)
        stack.clock.date = Self.now
        try await stack.store.delete(task)
    }

    /// The P5 probe. Sign-in drops the Trash's delete and remembers `x`. The pull leaves the Trash row
    /// alone, because the Trash came after the server's stamp. So the step is what brings it back. The
    /// Trash row is newer than the server's copy, so its own fields come back and the push sends them.
    @Test("a task edited, then trashed, while signed out keeps the edit at sign-in")
    func signedOutEditThenTrashKeepsTheEditAtSignIn() async throws {
        let stack = try makeStack(.signedOut)
        await stack.server.add("x", title: "old")                  // T0, before T1
        try await editThenTrashSignedOut(stack)

        await stack.engine.beginSignIn()
        let result = await stack.engine.sync(trigger: .signIn)

        #expect(result.error == nil)
        #expect(try await stack.repo.fetch(id: "x")?.title == "new")
        #expect(!(try await stack.isTrashed("x")))
        #expect(await stack.server.patches.map { $0.title } == ["new"])
        #expect(await stack.server.title(of: "x") == "new")
        #expect(await stack.server.deletedTaskIds.isEmpty)
        #expect(stack.cursor.rememberedDeletes().isEmpty)
    }

    @Test("a newer server copy still wins over a trashed edit at sign-in")
    func newerServerCopyStillWinsOverATrashedEdit() async throws {
        let stack = try makeStack(.signedOut)
        let serverStamp = "2026-11-07T11:30:00.000Z"               // T0, after T1 and before the Trash
        await stack.server.add("x", title: "old", clientUpdatedAt: serverStamp)
        try await editThenTrashSignedOut(stack)

        await stack.engine.beginSignIn()
        let result = await stack.engine.sync(trigger: .signIn)

        #expect(result.error == nil)
        let back = try #require(try await stack.repo.fetch(id: "x"))
        #expect(back.title == "old")
        #expect(back.updatedAt == WireDate.parse(serverStamp))
        #expect(await stack.server.patches.isEmpty)
        #expect(await stack.server.writtenTaskIds.isEmpty)
    }

    /// R-T5a: a tie isn't a win. Equal stamps keep the merge path, so the server's copy comes back.
    @Test("a trashed copy tied with the server's stamp takes the server copy")
    func tiedTrashedCopyTakesTheServerCopy() async throws {
        let stack = try makeStack(.signedOut)
        await stack.server.add("x", title: "old", clientUpdatedAt: Self.editedAt)
        try await editThenTrashSignedOut(stack)

        await stack.engine.beginSignIn()
        let result = await stack.engine.sync(trigger: .signIn)

        #expect(result.error == nil)
        #expect(try await stack.repo.fetch(id: "x")?.title == "old")
        #expect(await stack.server.patches.isEmpty)
        #expect(await stack.server.writtenTaskIds.isEmpty)
    }

    /// R20: one sub-millisecond instant, written through each real format. The server copy holds the
    /// `client_updated_at` that `TaskWireMapper.toWire` writes for it (`WireDate`, as the Share
    /// Extension's direct push sends a fresh stamp), and the Trash row holds what GRDB stored. Both round
    /// to the millisecond, so they tie, and a tie takes the merge path. If `WireDate` truncated while
    /// last-writer-wins rounded, about half of these rows would read 1 ms newer and send a pointless PATCH.
    @Test("a Trash row in the same millisecond as its server copy is not sent again at sign-in")
    func sameMillisecondTrashRowDoesNotResendAtSignIn() async throws {
        let stack = try makeStack(.signedOut)
        let ids = (0..<20).map { "x\($0)" }
        let editedAt = try #require(WireDate.parse(Self.editedAt)).timeIntervalSince1970
        for (i, id) in ids.enumerated() {
            // Each edit lands at its own fraction of its own millisecond.
            let fraction = (Double(i) + 0.5) / Double(ids.count)
            let instant = Date(timeIntervalSince1970: editedAt + (Double(2 * i) + fraction) / 1000)
            var task = try await stack.seedActive(id, title: "old")
            task.title = "new"
            stack.clock.date = instant
            try await stack.store.save(task)
            await stack.server.add(id, title: "new", clientUpdatedAt: WireDate.format(instant))
        }
        stack.clock.date = Self.now
        for id in ids { try await stack.store.delete(try #require(try await stack.repo.fetch(id: id))) }

        await stack.engine.beginSignIn()
        let result = await stack.engine.sync(trigger: .signIn)

        #expect(result.error == nil)
        #expect(await stack.server.patches.isEmpty)
        #expect(await stack.server.writtenTaskIds.isEmpty)
        #expect(try await stack.queue.all().isEmpty)
        for id in ids {
            #expect(try await stack.isActive(id))
            #expect(!(try await stack.isTrashed(id)))
        }
    }

    /// Section 8, reading 2, at a sign-in. An earlier sign-in remembered `x` and no run has listed it.
    /// Signed out, the user restores it, edits it, then archives it. The archive copy is newer than the
    /// server's and still stays archived, because the archive was the user's last act here.
    @Test("an archive row stays archived at sign-in, even when it's newer than the server's copy")
    func archivedRowStillStaysArchivedAtSignIn() async throws {
        let stack = try makeStack(.signedOut)
        await stack.server.add("x", title: "old")
        try await stack.seedTrashed("x")
        stack.cursor.rememberDeletes(["x"])
        try await stack.store.restoreFromTrash(id: "x")
        var task = try #require(try await stack.repo.fetch(id: "x"))
        stack.clock.date = try #require(WireDate.parse(Self.editedAt))
        task.title = "new"
        try await stack.store.save(task)
        stack.clock.date = Self.now
        try await stack.store.archive(task)

        await stack.engine.beginSignIn()
        let result = await stack.engine.sync(trigger: .signIn)

        #expect(result.error == nil)
        #expect(try await stack.archive.fetchAll().first { $0.id == "x" }?.title == "new")
        #expect(!(try await stack.isActive("x")))
        #expect(await stack.server.writtenTaskIds.isEmpty)
        #expect(await stack.server.deletedTaskIds.isEmpty)
        #expect(stack.cursor.rememberedDeletes().isEmpty)
    }

    /// A remembered Trash row for `x`, newer than the server's copy, so the step brings it back with its
    /// own fields and queues its update.
    private func newerTrashRow(_ stack: Stack) async throws {
        await stack.server.add("x", title: "old")
        try await stack.trash.trash(try await stack.seedActive("x", title: "new", updatedAt: Self.editedAt), at: Self.now)
        stack.cursor.rememberDeletes(["x"])
    }

    /// The bring-back write SQLite refuses: the queued update, or the move into the live table together
    /// with any removal of a queue row, so that a second write can't undo the first.
    enum RefusedBringBack: String, CaseIterable, Sendable {
        case queuedUpdate, move
        var triggers: [String] {
            switch self {
            case .queuedUpdate: ["BEFORE INSERT ON syncQueue"]
            case .move: ["BEFORE INSERT ON tasks", "BEFORE DELETE ON syncQueue"]
            }
        }
    }

    /// PF3. The move out of Trash and the queued update land together or not at all. Otherwise a failed
    /// move would leave an update that the push sends for a task still in Trash.
    @Test("a refused bring-back leaves the task in Trash with no queued update", arguments: RefusedBringBack.allCases)
    func bringBackFromTrashIsOneWrite(refusing write: RefusedBringBack) async throws {
        let stack = try makeStack(.signedIn)
        try await newerTrashRow(stack)
        try await stack.db.writer.write { db in
            for (n, timing) in write.triggers.enumerated() {
                try db.execute(sql: "CREATE TRIGGER refuse\(n) \(timing) BEGIN SELECT RAISE(ABORT, 'refused'); END")
            }
        }

        await #expect(throws: DatabaseError.self) {
            try await stack.engine.resurrectOnSight(token: Self.token, owner: "u1")
        }

        #expect(try await stack.queue.all().isEmpty)
        #expect(try await stack.isTrashed("x"))
        #expect(!(try await stack.isActive("x")))
        #expect(stack.cursor.rememberedDeletes() == ["x"])
    }

    /// The user deletes the task forever after the step read its Trash row. Bringing it back would
    /// upload a task the user just removed.
    @Test("a Delete Forever during the bring-back keeps the task deleted")
    func deleteForeverDuringBringBackStaysDeleted() async throws {
        let stack = try makeStack(.signedIn, racing: true)
        try await newerTrashRow(stack)
        let store = stack.store
        stack.racing?.afterBuriedRead = { try await store.deleteForever(id: "x") }

        let brought = try await stack.engine.resurrectOnSight(token: Self.token, owner: "u1")

        #expect(brought == 0)
        #expect(!(try await stack.isActive("x")))
        #expect(!(try await stack.isTrashed("x")))
        #expect(try await stack.queue.all().isEmpty)
    }

    /// The user restores the task and trashes it again after the step read its Trash row. The row holds
    /// the same copy, but the new delete is the user's latest act, as when it was queued before the step.
    @Test("an Undo then Trash during the bring-back keeps the task in Trash with its delete")
    func trashAgainDuringBringBackStaysTrashed() async throws {
        let stack = try makeStack(.signedIn, racing: true)
        try await newerTrashRow(stack)
        let store = stack.store, repo = stack.repo
        stack.racing?.afterBuriedRead = {
            try await store.restoreFromTrash(id: "x")
            try await store.delete(try #require(try await repo.fetch(id: "x")))
        }

        let brought = try await stack.engine.resurrectOnSight(token: Self.token, owner: "u1")

        #expect(brought == 0)
        #expect(try await stack.isTrashed("x"))
        #expect(!(try await stack.isActive("x")))
        #expect(try await stack.queue.all().map(\.operation) == [.delete])
    }

    /// A task created while signed out never reached the server. A signed-out Replace that leaves it
    /// out clears its queued create, so sign-in has nothing to post for it.
    @Test("a task created, then removed by Replace, while signed out isn't posted at sign-in")
    func signedOutCreateRemovedByReplaceIsNotPostedAtSignIn() async throws {
        let stack = try makeStack(.signedOut)
        await stack.server.add("k")
        try await stack.store.create(Task(id: "x", title: "Book the hall", urgent: true, important: true,
                                          createdAt: Self.now, updatedAt: Self.now))
        let kept = try await stack.seedActive("k")
        let backup = TaskExport(tasks: [kept], exportedAt: Self.now)
        try await stack.store.importTasks(try TaskExport.encode(backup), mode: .replace)

        await stack.engine.beginSignIn()
        let result = await stack.engine.sync(trigger: .signIn)

        #expect(result.error == nil)
        #expect(!(await stack.server.writtenTaskIds.contains("x")))
        #expect(!(await stack.server.has("x")))
        #expect(!(try await stack.isActive("x")))
        #expect(try await stack.queue.all().isEmpty)
    }
}
