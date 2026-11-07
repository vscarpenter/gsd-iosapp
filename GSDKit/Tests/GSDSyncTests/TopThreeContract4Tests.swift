import Foundation
import Testing
import GSDModel
import GSDStore
@testable import GSDSync
@testable import GSDWire

/// Top three spec section 6, the iOS rows of the named tests that mention the pick. The rest landed
/// with IOS-SAVED at contract 3 (`SavedAtUnreadPushTests`). Every case starts from an older build's
/// state, against a server that merges a PATCH like PocketBase (`UnreadServer`).
@MainActor
struct TopThreeContract4Tests {
    nonisolated private static let token = "eyJhbGciOiJIUzI1NiJ9.eyJpZCI6InUxIiwiZXhwIjo5OTk5OTk5OTk5fQ.x"
    nonisolated private static let now = WireDate.parse("2026-11-01T12:00:00.000Z")!
    nonisolated private static let pick = (date: "2026-10-20", rank: 1)

    private enum Device {
        /// A contract 3 build pulled past the record. It never read the pick.
        case contract3
        /// A contract 3 build signed out, which cleared its cursor and kept the version.
        case contract3SignedOut
        /// This build, after a completed pull stamped contract 4.
        case current
    }

    private struct Stack {
        let server: UnreadServer
        let repo: GRDBTaskRepository
        let queue: GRDBSyncQueueRepository
        let cursor: SyncCursor
        let engine: SyncEngine

        /// Task `a` as the device holds it, with no pick and no placement.
        @discardableResult
        func seedRow(at stamp: String, queued: Bool) async throws -> Task {
            let row = Task(id: "a", title: "Read later", urgent: false, important: true,
                           createdAt: try #require(WireDate.parse("2026-10-01T10:00:00.000Z")),
                           updatedAt: try #require(WireDate.parse(stamp)))
            try await repo.upsert(row)
            if queued { try await enqueue(row) }
            return row
        }

        func enqueue(_ payload: Task) async throws {
            try await queue.enqueue(SyncQueueItem(id: UUID().uuidString, taskId: payload.id, operation: .update,
                                                  timestamp: Int(payload.updatedAt.timeIntervalSince1970 * 1000),
                                                  payload: payload))
        }

        func local() async throws -> Task { try #require(try await repo.fetch(id: "a")) }

        func serverKeepsThePick() async -> Bool {
            let date = await server.focusDate(), rank = await server.focusRank()
            return date == TopThreeContract4Tests.pick.date && rank == Double(TopThreeContract4Tests.pick.rank)
        }
    }

    private func makeStack(_ device: Device, server: UnreadServer) throws -> Stack {
        let db = try AppDatabase.inMemory()
        let defaults = UserDefaults(suiteName: "top-three-c4-\(UUID().uuidString)")!
        let cursor = SyncCursor(defaults: defaults)
        switch device {
        case .contract3:
            defaults.set("2026-10-27 00:00:00.000Z", forKey: "gsd.sync.lastServerUpdated")
            defaults.set(3, forKey: "gsd.sync.contractVersion")
        case .contract3SignedOut:
            defaults.set(3, forKey: "gsd.sync.contractVersion")
        case .current:
            cursor.advance(maxApplied: WireDate.parse("2026-10-27T00:00:00.000Z"))
        }
        let repo = GRDBTaskRepository(db)
        let queue = GRDBSyncQueueRepository(db)
        let engine = SyncEngine(client: PocketBaseClient(baseURL: "https://top-three.test", executor: server),
                                tasks: repo, queue: queue, cursor: cursor, deviceId: "ios",
                                tokenProvider: { Self.token }, now: { Self.now }, throttleMs: 0)
        return Stack(server: server, repo: repo, queue: queue, cursor: cursor, engine: engine)
    }

    private func pickedServer(clientUpdatedAt: String = UnreadServer.savedStamp) -> UnreadServer {
        UnreadServer(clientUpdatedAt: clientUpdatedAt, saved: false, focus: Self.pick)
    }

    // MARK: C4-1

    @Test("sign-out, upgrade, and sign-in keep the server pick")
    func signOutUpgradeAndSignInKeepTheServerPick() async throws {
        let stack = try makeStack(.contract3SignedOut, server: pickedServer())
        try await stack.seedRow(at: "2026-10-21T10:00:00.000Z", queued: false)

        _ = await stack.engine.sync(trigger: .signIn)

        #expect(await stack.serverKeepsThePick())
        #expect(try await stack.local().focusRank == Self.pick.rank)
    }

    // MARK: C4-4

    @Test("a locally newer row gets the server pick through the backfill")
    func aLocallyNewerRowGetsTheServerPick() async throws {
        let stack = try makeStack(.contract3, server: pickedServer())
        let row = try await stack.seedRow(at: "2026-10-21T10:00:00.000Z", queued: false)

        let result = await stack.engine.sync(trigger: .launch)

        let local = try await stack.local()
        #expect(local.focusDate == Self.pick.date && local.focusRank == Self.pick.rank)
        #expect(local.updatedAt == row.updatedAt && local.title == row.title)   // only the pick moved
        #expect(result.error == nil && !stack.cursor.needsBackfill())
    }

    /// A Return queued on a contract 3 build reads as `savedAt` nil, and contract 3 already read Saved,
    /// so the contract 4 backfill must leave it alone and let the push clear the placement.
    @Test("a real return survives the contract 4 backfill")
    func aRealReturnSurvivesTheContract4Backfill() async throws {
        let stack = try makeStack(.contract3, server: UnreadServer())
        try await stack.seedRow(at: "2026-10-21T10:00:00.000Z", queued: true)

        _ = await stack.engine.sync(trigger: .launch)

        #expect(await stack.server.savedAt() == "")
        #expect(try await stack.local().isSaved == false)
    }

    @Test("an ordinary pull leaves a local un-pick alone")
    func anOrdinaryPullLeavesALocalUnpickAlone() async throws {
        let stack = try makeStack(.current, server: pickedServer())
        try await stack.seedRow(at: "2026-10-21T10:00:00.000Z", queued: true)

        _ = await stack.engine.sync(trigger: .launch)

        #expect(try await stack.local().focusDate == nil)
        #expect(await stack.server.focusDate() == "")                        // the un-pick reached the server
    }

    @Test("the backfill leaves the queue empty when nothing changed")
    func theBackfillLeavesTheQueueEmptyWhenNothingChanged() async throws {
        let stack = try makeStack(.contract3, server: pickedServer())
        try await stack.seedRow(at: UnreadServer.savedStamp, queued: false)

        _ = await stack.engine.sync(trigger: .launch)

        #expect(try await stack.local().focusRank == Self.pick.rank)
        #expect(try await stack.queue.all().isEmpty)
        #expect(await stack.server.writes.isEmpty)
    }

    // MARK: C4-6

    @Test("a queued payload from an older build keeps the server pick")
    func aQueuedPayloadFromAnOlderBuildKeepsTheServerPick() async throws {
        let stack = try makeStack(.contract3, server: pickedServer())
        try await stack.seedRow(at: "2026-10-21T10:00:00.000Z", queued: true)

        _ = await stack.engine.sync(trigger: .launch)

        let write = try #require(await stack.server.writes.first)
        #expect(write.focusDate == Self.pick.date && write.focusRank == Double(Self.pick.rank))
        #expect(await stack.serverKeepsThePick())
    }

    @Test("a same-version row with a queued change keeps the server pick")
    func aSameVersionRowWithAQueuedChangeKeepsTheServerPick() async throws {
        let stack = try makeStack(.contract3, server: pickedServer())
        try await stack.seedRow(at: UnreadServer.savedStamp, queued: true)

        _ = await stack.engine.sync(trigger: .launch)

        #expect(await stack.serverKeepsThePick())
        #expect(try await stack.local().focusRank == Self.pick.rank)
    }

    @Test("a queued item for a row that's gone omits both keys")
    func aQueuedItemForARowThatIsGoneOmitsBothKeys() async throws {
        let stack = try makeStack(.current, server: pickedServer())
        try await stack.enqueue(Task(id: "a", title: "Archived since", urgent: false, important: true,
                                     createdAt: Self.now, updatedAt: try #require(WireDate.parse("2026-10-21T10:00:00.000Z"))))

        _ = await stack.engine.pushNow()

        #expect(await stack.server.writes.first?.sentFocus == false)
        #expect(await stack.serverKeepsThePick())
    }

    // MARK: C4-2 with C4-4 (S-SPEC-01)

    @Test("a far-future remote with a queued edit keeps the server pick through the backfill")
    func aFarFutureRemoteWithAQueuedEditKeepsTheServerPick() async throws {
        let stack = try makeStack(.contract3, server: pickedServer(clientUpdatedAt: "2027-01-01T00:00:00.000Z"))
        try await stack.seedRow(at: "2026-10-21T10:00:00.000Z", queued: true)

        _ = await stack.engine.sync(trigger: .launch)

        #expect(await stack.server.writes.count == 1)
        #expect(await stack.serverKeepsThePick())
    }
}
