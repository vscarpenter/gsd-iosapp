import Foundation
import Testing
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
    private(set) var listings = 0
    private var sessionDead = false
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

    func killSession() { sessionDead = true }
    func listIncompletely() { incomplete = true }
    func failListings(_ fail: Bool) { listingFails = fail }
    func has(_ taskId: String) -> Bool { records[taskId] != nil }
    /// Runs once, the next time the account is listed: something else happening while a run awaits.
    func whenListed(_ hook: @escaping @Sendable () -> Void) { onListing = hook }

    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        if url.path.hasSuffix("/auth-refresh") {
            if sessionDead { return (Data(#"{"message":"The request requires valid record authorization token."}"#.utf8), response(url, 401)) }
            return (Data(#"{"token":"fresh","record":{"id":"u1","email":"u1@example.com"}}"#.utf8), response(url, 200))
        }
        switch request.httpMethod ?? "GET" {
        case "GET": return try list(request, url: url)
        case "DELETE":
            if let taskId = records.first(where: { $0.value["id"] as? String == url.lastPathComponent })?.key {
                records[taskId] = nil
                deletedTaskIds.append(taskId)
            }
            return (Data(), response(url, 204))
        default:   // POST creates, PATCH merges
            let body = try #require(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
            let taskId = try #require(body["task_id"] as? String)
            var record = records[taskId] ?? ["id": "rec_\(taskId)", "updated": "2026-11-07 12:00:00.000Z"]
            record.merge(body.filter { $0.key != "id" }) { _, new in new }
            records[taskId] = record
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

        func enqueueDelete(_ id: String, payload: Task? = nil) async throws {
            try await queue.enqueue(SyncQueueItem(id: UUID().uuidString, taskId: id, operation: .delete,
                                                  timestamp: Int(ResurrectOnSightTests.now.timeIntervalSince1970 * 1000),
                                                  payload: payload))
        }

        func isActive(_ id: String) async throws -> Bool { try await repo.fetch(id: id) != nil }
        func isTrashed(_ id: String) async throws -> Bool { try await trash.fetchAll().contains { $0.id == id } }
    }

    private func makeStack(_ device: Device, server: AccountServer = AccountServer()) throws -> Stack {
        let db = try AppDatabase.inMemory()
        let defaults = UserDefaults(suiteName: "resurrect-\(UUID().uuidString)")!
        let cursor = SyncCursor(defaults: defaults)
        cursor.advance(maxApplied: WireDate.parse("2026-11-02T00:00:00.000Z"))
        if device == .signedOut { cursor.clear() }
        let repo = GRDBTaskRepository(db)
        let queue = GRDBSyncQueueRepository(db)
        let trash = GRDBTrashRepository(db)
        let archive = GRDBArchiveRepository(db)
        let engine = SyncEngine(client: PocketBaseClient(baseURL: "https://resurrect.test", executor: server),
                                tasks: repo, queue: queue, tombstones: GRDBTombstoneRepository(db), cursor: cursor,
                                deviceId: "ios", tokenProvider: { Self.token }, rawToken: { Self.token },
                                now: { Self.now }, throttleMs: 0)
        let store = TaskStore(repository: repo, smartViewRepository: GRDBSmartViewRepository(db),
                              archiveRepository: archive, trashRepository: trash, defaults: defaults,
                              clock: { Self.now }, syncQueue: queue)
        return Stack(server: server, db: db, repo: repo, queue: queue, trash: trash, archive: archive,
                     cursor: cursor, engine: engine, store: store)
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

    @Test("a delete made while signed in still deletes on the server")
    func aDeleteMadeSignedInStillDeletes() async throws {
        let stack = try makeStack(.signedIn)
        await stack.server.add("t1")
        try await stack.store.delete(try await stack.seedActive("t1"))

        _ = await stack.engine.sync(trigger: .manual)

        #expect(await stack.server.deletedTaskIds == ["t1"])
    }
}
