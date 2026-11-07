import Foundation
import Testing
import GSDModel
import GSDStore
@testable import GSDSync
@testable import GSDWire

/// The finding's server (`sprint/findings/saved-at-exposure.md`): one task another device Saved at
/// 10-20. Lists by the `updated` filter, so an older build's cursor past the record hides it from an
/// incremental pull, and merges a PATCH body like PocketBase, so a key left off keeps its value.
private actor UnreadServer: RequestExecuting {
    static let savedStamp = "2026-10-20T10:00:00.000Z"

    struct Write: Sendable {
        let sentSavedAt: Bool
        let savedAt: String?
    }

    private var record: [String: Any]
    private(set) var methods: [String] = []
    private(set) var writes: [Write] = []
    private var listingFails = false

    init(clientUpdatedAt: String = savedStamp) {
        record = ["id": "rec_a", "task_id": "a", "owner": "u1", "title": "Read later", "description": "",
                  "urgent": false, "important": true, "saved_at": Self.savedStamp,
                  "client_created_at": "2026-10-01T10:00:00.000Z", "client_updated_at": clientUpdatedAt,
                  "updated": "2026-10-20 10:00:01.000Z", "device_id": "web"]
    }

    func failListing() { listingFails = true }
    func savedAt() -> String? { record["saved_at"] as? String }
    func completed() -> Bool { record["completed"] as? Bool ?? false }

    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let method = request.httpMethod ?? "GET"
        methods.append(method)
        if method == "GET" {
            if listingFails { return (Data(#"{"message":"unavailable"}"#.utf8), response(request, status: 503)) }
            let items: [[String: Any]] = listed(by: request) ? [record] : []
            let page: [String: Any] = ["page": 1, "perPage": 200, "totalItems": items.count, "totalPages": 1, "items": items]
            return (try JSONSerialization.data(withJSONObject: page), response(request, status: 200))
        }
        let body = try #require(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        writes.append(Write(sentSavedAt: body["saved_at"] != nil, savedAt: body["saved_at"] as? String))
        record.merge(body) { _, new in new }
        return (try JSONSerialization.data(withJSONObject: record), response(request, status: 200))
    }

    private func response(_ request: URLRequest, status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    /// The filter is `updated >= "<since>"`; the record is listed when its server stamp qualifies.
    private func listed(by request: URLRequest) -> Bool {
        guard let url = request.url,
              let filter = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                  .queryItems?.first(where: { $0.name == "filter" })?.value else { return true }
        let quoted = filter.split(separator: "\"")
        guard quoted.count >= 2, let since = WireDate.parse(String(quoted[1])),
              let updated = WireDate.parse(record["updated"] as? String ?? "") else { return true }
        return updated >= since
    }
}

/// Goal 0 (owner item 7): a device that never read `saved_at` for a row must not send it empty.
/// Each case starts from the finding's state. Case ids (a1 to c4) match the finding's tables.
@MainActor
struct SavedAtUnreadPushTests {
    nonisolated private static let token = "eyJhbGciOiJIUzI1NiJ9.eyJpZCI6InUxIiwiZXhwIjo5OTk5OTk5OTk5fQ.x"
    nonisolated private static let now = WireDate.parse("2026-11-01T12:00:00.000Z")!

    /// What the device's sync defaults hold before the run.
    private enum Device {
        /// An older build pulled past the record and never stamped a contract.
        case olderBuild
        /// An older build signed out, which cleared its cursor. It never stamped a contract either.
        case olderBuildSignedOut
        /// This build, after a completed pull stamped contract 3.
        case currentBuild
    }

    private struct Stack {
        let server: UnreadServer
        let repo: GRDBTaskRepository
        let queue: GRDBSyncQueueRepository
        let cursor: SyncCursor
        let engine: SyncEngine
        let store: TaskStore

        /// The row an older build stored for task `a`: no `savedAt`, because it never read the key.
        func seedRow(at stamp: String, completed: Bool = false, queued: Bool) async throws {
            let updated = try #require(WireDate.parse(stamp))
            let created = try #require(WireDate.parse("2026-10-01T10:00:00.000Z"))
            let row = Task(id: "a", title: "Read later", urgent: false, important: true,
                           completed: completed, completedAt: completed ? updated : nil,
                           createdAt: created, updatedAt: updated)
            try await repo.upsert(row)
            if queued { try await enqueue(row) }
        }

        func enqueue(_ payload: Task) async throws {
            try await queue.enqueue(SyncQueueItem(id: UUID().uuidString, taskId: payload.id, operation: .update,
                                                  timestamp: Int(payload.updatedAt.timeIntervalSince1970 * 1000),
                                                  payload: payload))
        }

        func localSavedAt() async throws -> String? {
            try await repo.fetch(id: "a")?.savedAt.map { WireDate.format($0) }
        }
    }

    private func makeStack(_ device: Device, server: UnreadServer = UnreadServer()) throws -> Stack {
        let db = try AppDatabase.inMemory()
        let repo = GRDBTaskRepository(db)
        let queue = GRDBSyncQueueRepository(db)
        let defaults = UserDefaults(suiteName: "saved-unread-\(UUID().uuidString)")!
        let cursor = SyncCursor(defaults: defaults)
        switch device {
        case .olderBuild: defaults.set("2026-10-27 00:00:00.000Z", forKey: "gsd.sync.lastServerUpdated")
        case .olderBuildSignedOut: break
        case .currentBuild: cursor.advance(maxApplied: WireDate.parse("2026-10-27T00:00:00.000Z"))
        }
        let engine = SyncEngine(client: PocketBaseClient(baseURL: "https://saved-unread.test", executor: server),
                                tasks: repo, queue: queue, cursor: cursor, deviceId: "ios",
                                tokenProvider: { Self.token }, now: { Self.now }, throttleMs: 0)
        let store = TaskStore(repository: repo, smartViewRepository: GRDBSmartViewRepository(db),
                              archiveRepository: GRDBArchiveRepository(db), trashRepository: GRDBTrashRepository(db),
                              defaults: defaults, clock: { Self.now }, syncQueue: queue)
        return Stack(server: server, repo: repo, queue: queue, cursor: cursor, engine: engine, store: store)
    }

    // MARK: (a) A queued payload from before Saved, first sync after the upgrade

    @Test("a1: a queued edit newer than the Save keeps the server's saved_at")
    func queuedEditNewerThanTheSave() async throws {
        let stack = try makeStack(.olderBuild)
        try await stack.seedRow(at: "2026-10-21T10:00:00.000Z", queued: true)

        let result = await stack.engine.sync(trigger: .launch)

        #expect(result.error == nil)
        #expect(await stack.server.savedAt() == UnreadServer.savedStamp)
        #expect(try await stack.localSavedAt() == UnreadServer.savedStamp)
    }

    @Test("a2: a same-version row with a queued change keeps the server's saved_at")
    func sameVersionRowWithAQueuedChange() async throws {
        let stack = try makeStack(.olderBuild)
        try await stack.seedRow(at: UnreadServer.savedStamp, queued: true)

        _ = await stack.engine.sync(trigger: .launch)

        #expect(await stack.server.savedAt() == UnreadServer.savedStamp)
        #expect(try await stack.localSavedAt() == UnreadServer.savedStamp)
    }

    @Test("a3 (control): a queued edit older than the Save is dropped and the pull repairs the row")
    func queuedEditOlderThanTheSave() async throws {
        let stack = try makeStack(.olderBuild)
        try await stack.seedRow(at: "2026-10-19T10:00:00.000Z", queued: true)

        _ = await stack.engine.sync(trigger: .launch)

        #expect(await stack.server.writes.isEmpty)
        #expect(await stack.server.savedAt() == UnreadServer.savedStamp)
        #expect(try await stack.localSavedAt() == UnreadServer.savedStamp)
    }

    // MARK: (b) Signed out on an older build, upgrade, sign in

    /// Finding case b1, the broadest one: no pending edit, only a row at the Saved version.
    @Test("backfill runs with a null cursor")
    func backfillRunsWithANullCursor() async throws {
        let stack = try makeStack(.olderBuildSignedOut)
        try await stack.seedRow(at: UnreadServer.savedStamp, queued: false)

        let result = await stack.engine.sync(trigger: .signIn)

        #expect(result.error == nil)
        #expect(await stack.server.savedAt() == UnreadServer.savedStamp)
        #expect(try await stack.localSavedAt() == UnreadServer.savedStamp)
        #expect(!stack.cursor.needsBackfill())
    }

    /// Finding case b2.
    @Test("sign-out, upgrade, and sign-in keep the server's saved_at")
    func signOutUpgradeSignInWithANewerEdit() async throws {
        let stack = try makeStack(.olderBuildSignedOut)
        try await stack.seedRow(at: "2026-10-21T10:00:00.000Z", queued: false)

        _ = await stack.engine.sync(trigger: .signIn)

        #expect(await stack.server.savedAt() == UnreadServer.savedStamp)
        #expect(try await stack.localSavedAt() == UnreadServer.savedStamp)
    }

    @Test("b3 (control): a signed-out row older than the Save takes the server's copy")
    func signedOutRowOlderThanTheSave() async throws {
        let stack = try makeStack(.olderBuildSignedOut)
        try await stack.seedRow(at: "2026-10-19T10:00:00.000Z", queued: false)

        _ = await stack.engine.sync(trigger: .signIn)

        #expect(await stack.server.writes.isEmpty)
        #expect(await stack.server.savedAt() == UnreadServer.savedStamp)
        #expect(try await stack.localSavedAt() == UnreadServer.savedStamp)
    }

    // MARK: (c) A push-only drain before the first sync after the upgrade

    /// Finding case c1.
    @Test("a push-only drain runs a full sync while a backfill is due")
    func pushOnlyDrainRunsAFullSyncWhileABackfillIsDue() async throws {
        let stack = try makeStack(.olderBuild)
        try await stack.seedRow(at: "2026-10-21T10:00:00.000Z", queued: true)

        _ = await stack.engine.pushNow()

        #expect(await stack.server.savedAt() == UnreadServer.savedStamp)
        #expect(try await stack.localSavedAt() == UnreadServer.savedStamp)
        #expect(!stack.cursor.needsBackfill())
    }

    @Test("c2 (control): a push-only drain drops a queued edit older than the Save")
    func pushOnlyDrainDropsAnOlderQueuedEdit() async throws {
        let stack = try makeStack(.olderBuild)
        try await stack.seedRow(at: "2026-10-19T10:00:00.000Z", queued: true)

        _ = await stack.engine.pushNow()

        #expect(await stack.server.writes.isEmpty)
        #expect(await stack.server.savedAt() == UnreadServer.savedStamp)
    }

    @Test("c3: an edit on the upgraded build before the backfill keeps the server's saved_at")
    func freshEditBeforeTheBackfill() async throws {
        let stack = try makeStack(.olderBuild)
        try await stack.seedRow(at: UnreadServer.savedStamp, queued: false)
        var edit = try #require(try await stack.repo.fetch(id: "a"))
        edit.title = "Read this week"

        try await stack.store.save(edit)
        _ = await stack.engine.pushNow()

        #expect(await stack.server.writes.last?.savedAt == UnreadServer.savedStamp)
        #expect(await stack.server.savedAt() == UnreadServer.savedStamp)
    }

    @Test("c4 (control): the same edit after the backfill keeps the server's saved_at")
    func freshEditAfterTheBackfill() async throws {
        let stack = try makeStack(.olderBuild)
        try await stack.seedRow(at: UnreadServer.savedStamp, queued: false)
        _ = await stack.engine.sync(trigger: .launch)
        var edit = try #require(try await stack.repo.fetch(id: "a"))
        edit.title = "Read this week"

        try await stack.store.save(edit)
        _ = await stack.engine.pushNow()

        #expect(await stack.server.writes.last?.savedAt == UnreadServer.savedStamp)
        #expect(await stack.server.savedAt() == UnreadServer.savedStamp)
    }

    // MARK: The backfill's order, and what it must leave alone

    @Test("backfill pulls before it pushes")
    func backfillPullsBeforeItPushes() async throws {
        let stack = try makeStack(.olderBuild)
        try await stack.seedRow(at: "2026-10-21T10:00:00.000Z", queued: true)

        _ = await stack.engine.sync(trigger: .launch)

        let methods = await stack.server.methods
        let firstWrite = try #require(methods.firstIndex(of: "PATCH"))
        #expect(methods.first == "GET" && methods.firstIndex(of: "GET")! < firstWrite)
        #expect(await stack.server.writes.first?.savedAt == UnreadServer.savedStamp)  // the row the pull repaired
    }

    @Test("a failed backfill pull pushes nothing and stamps nothing")
    func failedBackfillPullPushesNothingAndStampsNothing() async throws {
        let stack = try makeStack(.olderBuild)
        try await stack.seedRow(at: "2026-10-21T10:00:00.000Z", queued: true)
        await stack.server.failListing()

        let result = await stack.engine.sync(trigger: .launch)

        #expect(result.error != nil)
        #expect(await stack.server.writes.isEmpty)
        #expect(stack.cursor.needsBackfill())
        #expect(try await stack.queue.all().count == 1)
    }

    /// A real Return queued on this build, then sign-out and sign-in. Sign-out must keep the stored
    /// contract, or the next sync would read as an older build's and copy the placement back.
    @Test("sign-out on the current build doesn't trigger a backfill")
    func signOutOnTheCurrentBuildDoesNotTriggerABackfill() async throws {
        let stack = try makeStack(.currentBuild)
        try await stack.seedRow(at: "2026-10-21T10:00:00.000Z", queued: true)

        await stack.engine.resetCursor()
        #expect(!stack.cursor.needsBackfill())
        _ = await stack.engine.sync(trigger: .signIn)

        #expect(await stack.server.savedAt() == "")
        #expect(try await stack.localSavedAt() == nil)
    }

    @Test("a task completed on the old build after the Save ends completed, not also Saved")
    func taskCompletedOnTheOldBuildAfterTheSave() async throws {
        let stack = try makeStack(.olderBuild)
        try await stack.seedRow(at: "2026-10-21T10:00:00.000Z", completed: true, queued: true)

        _ = await stack.engine.sync(trigger: .launch)

        let local = try #require(try await stack.repo.fetch(id: "a"))
        #expect(local.completed && !local.isSaved)
        #expect(await stack.server.completed())
        #expect(await stack.server.savedAt() == "")
    }

    /// A far-future remote stamp holds the pull off while a write is queued, so the push heals the
    /// record (S-AND-02). During the backfill that push must still carry the placement. The name is
    /// the spec's (S-SPEC-01); this is its `saved_at` version, and IOS-C4 adds the pick version.
    @Test("a far-future remote with a queued edit keeps the server pick through the backfill")
    func farFutureRemoteWithAQueuedEdit() async throws {
        let stack = try makeStack(.olderBuild, server: UnreadServer(clientUpdatedAt: "2027-01-01T00:00:00.000Z"))
        try await stack.seedRow(at: "2026-10-21T10:00:00.000Z", queued: false)
        var edit = try #require(try await stack.repo.fetch(id: "a"))
        edit.title = "Read this week"                                   // differs from the server's title
        try await stack.repo.upsert(edit)
        try await stack.enqueue(edit)

        _ = await stack.engine.sync(trigger: .launch)

        #expect(await stack.server.writes.count == 1)
        #expect(await stack.server.savedAt() == UnreadServer.savedStamp)
        #expect(try await stack.repo.fetch(id: "a")?.title == "Read this week")   // the hold-off kept the edit
    }

    @Test("a queued item for a row that's gone leaves saved_at off the wire")
    func queuedItemForAGoneRowOmitsSavedAt() async throws {
        let stack = try makeStack(.currentBuild)
        let stamp = try #require(WireDate.parse("2026-10-21T10:00:00.000Z"))
        try await stack.enqueue(Task(id: "a", title: "Read later", urgent: false, important: true,
                                     createdAt: stamp, updatedAt: stamp))

        _ = await stack.engine.pushNow()

        #expect(await stack.server.writes.first?.sentSavedAt == false)
        #expect(await stack.server.savedAt() == UnreadServer.savedStamp)
    }
}
