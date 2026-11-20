import Testing
import Foundation
import GSDModel
import GSDStore
@testable import GSDSync
@testable import GSDWire

struct LWWTests {
    private let t0 = Date(timeIntervalSince1970: 1000.000)
    private let t1 = Date(timeIntervalSince1970: 1000.500)   // +500 ms

    @Test func remoteNewerTakesRemote() {
        #expect(LWW.resolve(localUpdatedAt: t0, remoteClientUpdatedAt: t1) == .takeRemote)
    }

    @Test func localNewerKeepsLocal() {
        #expect(LWW.resolve(localUpdatedAt: t1, remoteClientUpdatedAt: t0) == .keepLocal)
    }

    @Test func equalMillisecondsIsNoOp() {
        #expect(LWW.resolve(localUpdatedAt: t0, remoteClientUpdatedAt: t0) == .noOp)
    }

    @Test func unparseableRemoteIsNoOp() {
        #expect(LWW.resolve(localUpdatedAt: t0, remoteClientUpdatedAt: nil) == .noOp)
    }

    @Test func noLocalTakesRemote() {
        #expect(LWW.resolve(localUpdatedAt: nil, remoteClientUpdatedAt: t0) == .takeRemote)
    }

    @Test func subMillisecondDifferenceInSameBucketIsNoOp() {
        let a = Date(timeIntervalSince1970: 1000.5000)
        let b = Date(timeIntervalSince1970: 1000.5004)   // same ms bucket
        #expect(LWW.resolve(localUpdatedAt: a, remoteClientUpdatedAt: b) == .noOp)
    }

    // MARK: Far-future stamps (B-44, web MAX_CLIENT_CLOCK_SKEW_MS)

    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private let ceiling = Date(timeIntervalSince1970: 2_000_000_300)     // now + 5 minutes
    private let pastCeiling = Date(timeIntervalSince1970: 2_000_000_300.001)

    @Test func cappedLeavesAStampAtTheCeilingAlone() {
        #expect(LWW.capped(ceiling, now: now) == ceiling)
    }

    @Test func cappedBringsAStampPastTheCeilingDownToIt() {
        #expect(LWW.capped(pastCeiling, now: now) == ceiling)
    }

    @Test func aStampAtTheCeilingCanBeNewer() {
        #expect(LWW.isRemoteNewer(ceiling, than: now, now: now))
    }

    @Test func aStampPastTheCeilingIsNeverNewer() {
        #expect(!LWW.isRemoteNewer(pastCeiling, than: now, now: now))
    }

    @Test func anOlderOrEqualStampIsNotNewer() {
        #expect(!LWW.isRemoteNewer(t0, than: t1, now: now))
        #expect(!LWW.isRemoteNewer(t0, than: t0, now: now))
    }

    @Test("guardedVersion bumps only an equal stamp")
    func guardedVersionBumpsEqualStamp() {
        #expect(LWW.guardedVersion(outgoing: "2026-11-19T17:00:00.000Z", expected: "2026-11-19T17:00:00.000Z")
                == "2026-11-19T17:00:00.001Z")
        #expect(LWW.guardedVersion(outgoing: "2026-11-19T17:30:00.000Z", expected: "2026-11-19T17:00:00.000Z")
                == "2026-11-19T17:30:00.000Z")
        // A listed stamp in another spelling is not byte-equal, so the server accepts the outgoing one.
        #expect(LWW.guardedVersion(outgoing: "2026-11-19T17:00:00.000Z", expected: "2026-11-19 17:00:00Z")
                == "2026-11-19T17:00:00.000Z")
    }

    // MARK: Rounding to the millisecond (R20)

    /// 1000.125 s is exact in binary, so the reference stamp carries no error of its own.
    @Test("a stamp rounds to the nearest millisecond")
    func msRoundsToTheNearestMillisecond() {
        let x = Date(timeIntervalSince1970: 1000.125)
        let justBelow = Date(timeIntervalSince1970: 1000.1249996)   // 0.0004 ms short of x
        let justAbove = Date(timeIntervalSince1970: 1000.1250004)   // 0.0004 ms past x
        #expect(LWW.resolve(localUpdatedAt: justBelow, remoteClientUpdatedAt: x) == .noOp)
        #expect(LWW.resolve(localUpdatedAt: justAbove, remoteClientUpdatedAt: x) == .noOp)
    }

    private static let syncNow = WireDate.parse("2026-11-19T18:00:00.000Z")!
    private static let createdAt = WireDate.parse("2026-11-01T00:00:00.000Z")!

    private static func row(_ id: String, at updatedAt: Date) -> Task {
        Task(id: id, title: "edited", urgent: false, important: false, createdAt: createdAt, updatedAt: updatedAt)
    }

    private static func ms(_ stamp: String) throws -> Int {
        Int((try #require(WireDate.parse(stamp)).timeIntervalSince1970 * 1000).rounded())
    }

    /// Canary: `stored` came back from GRDB a hair below `stamp`'s millisecond, so truncating it gives the
    /// millisecond before. If Foundation or GRDB stop doing that, these cases no longer test rounding.
    private static func expectReadsBackLow(_ stored: Date, as stamp: String) throws {
        #expect(Int(stored.timeIntervalSince1970 * 1000) == (try ms(stamp)) - 1)
    }

    /// A row stamp and its +1 ms bump, where the bump reads back low through GRDB. These are the stamps
    /// `restampAtAnyMillisecond` pins (SyncEngineGuardedWriteTests).
    private static let readLowBumps: [(String, String)] = [
        ("2026-11-19T17:00:00.008Z", "2026-11-19T17:00:00.009Z"),
        ("2026-11-19T17:00:00.014Z", "2026-11-19T17:00:00.015Z"),
    ]

    /// The queued update carries the stamp the server lists, so the push bumps it by 1 ms and restamps the
    /// row (`restampIfUnchanged`). GRDB stores the bump rounded, and it reads back a hair low. A truncating
    /// comparison read the row as a millisecond older than the server's copy and logged a conflict.
    @Test("a restamped row ties with its bumped server copy, so the next pull logs no conflict",
          arguments: readLowBumps)
    func restampedEqualStampLogsNoConflict(row stamp: String, bump: String) async throws {
        let server = GuardedServer()
        await server.put(recordId: "rec1", taskId: "a", version: stamp)
        let db = try AppDatabase.inMemory()
        let tasks = GRDBTaskRepository(db)
        let queue = GRDBSyncQueueRepository(db)
        let engine = SyncEngine(client: PocketBaseClient(baseURL: "https://lww.test", executor: server),
                                tasks: tasks, queue: queue,
                                cursor: SyncCursor(defaults: UserDefaults(suiteName: "lww.\(UUID().uuidString)")!),
                                deviceId: "ios", tokenProvider: { "TOK" }, now: { Self.syncNow }, throttleMs: 0)
        let local = Self.row("a", at: try #require(WireDate.parse(stamp)))
        try await tasks.upsert(local)
        try await queue.enqueue(SyncQueueItem(id: "q1", taskId: "a", operation: .update,
                                              timestamp: try Self.ms(stamp), payload: local))

        _ = try await engine.push(token: "TOK", owner: "u1")
        #expect(await server.version(of: "rec1") == bump)
        try Self.expectReadsBackLow(try #require(try await tasks.fetch(id: "a")).updatedAt, as: bump)
        let pulled = try await engine.pull(token: "TOK", since: "1970-01-01 00:00:00.000Z")

        #expect(pulled.conflicts == 0)
        #expect(pulled.applied == 0)
    }

    private final class Clock: @unchecked Sendable { var date = Date(timeIntervalSince1970: 0) }

    private static func jwt(_ id: String) -> String {
        let payload = Data(#"{"id":"\#(id)","exp":9999999999}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "h.\(payload).s"
    }

    /// The R24 window. The local row is at the row stamp, and its server copy is this device's own +1 ms
    /// bump, as when the PATCH landed but its 204 was lost. The real archive reads the clock at `fraction`
    /// of the bump's millisecond. Below half, GRDB stores the archive time as the bump's millisecond, and
    /// it reads back a hair low. A truncating comparison then saw the bump as newer than the archive, so
    /// the pull brought the task back. The push, excusing its own bump (F3), still sent the delete, and
    /// reconcile removed the live copy. The 0.75 case is the control: the archive time rounds up, so the
    /// pull leaves the archive alone either way.
    @Test("an archive in the same millisecond as this device's own write keeps the task",
          arguments: readLowBumps.map { ($0.0, $0.1, 0.25) } + [(readLowBumps[0].0, readLowBumps[0].1, 0.75)])
    @MainActor func archiveInTheSameMillisecondAsAnOwnWriteKeepsTheTask(row stamp: String, bump: String,
                                                                         fraction: Double) async throws {
        let db = try AppDatabase.inMemory()
        let tasks = GRDBTaskRepository(db)
        let queue = GRDBSyncQueueRepository(db)
        let archive = GRDBArchiveRepository(db)
        let clock = Clock()
        let store = TaskStore(repository: tasks, smartViewRepository: GRDBSmartViewRepository(db),
                              archiveRepository: archive, trashRepository: GRDBTrashRepository(db),
                              defaults: UserDefaults(suiteName: "lww.\(UUID().uuidString)")!,
                              clock: { clock.date }, syncQueue: queue)
        let cursor = SyncCursor(defaults: UserDefaults(suiteName: "lww.\(UUID().uuidString)")!)
        cursor.advance(maxApplied: Date(timeIntervalSince1970: 1_000)); cursor.markBackfilled()
        let token = Self.jwt("u1")
        let server = GuardedServer()
        await server.put(recordId: "rec1", taskId: "a", version: bump, deviceId: "ios")
        let engine = SyncEngine(client: PocketBaseClient(baseURL: "https://lww.test", executor: server),
                                tasks: tasks, queue: queue, tombstones: GRDBTombstoneRepository(db), cursor: cursor,
                                deviceId: "ios", tokenProvider: { token }, rawToken: { token },
                                now: { Self.syncNow }, throttleMs: 0)
        let local = Self.row("a", at: try #require(WireDate.parse(stamp)))
        try await tasks.upsert(local)
        clock.date = Date(timeIntervalSince1970: (Double(try Self.ms(bump)) + fraction) / 1000)
        try await store.archive(local)
        if fraction < 0.5 {
            try Self.expectReadsBackLow(try #require(try await archive.fetchAllStamped().first).stampedAt, as: bump)
        }

        let result = await engine.sync(trigger: .manual)

        #expect(result.error == nil)
        #expect(try await tasks.fetch(id: "a") == nil)
        #expect(try await archive.fetchAll().map(\.id) == ["a"])
        #expect(await server.deletes.map(\.expectedVersion) == [bump])
        #expect(await server.holds("rec1") == false)
    }

    /// The broad version of the cases above, with no push or pull: one second of millisecond stamps goes
    /// into GRDB and comes back, and each must tie with its own millisecond.
    @Test("every stamp read back from GRDB ties with the millisecond it stores")
    func storedStampsTieWithTheirMillisecond() async throws {
        let first = try Self.ms("2026-11-19T17:00:00.000Z")
        let tasks = GRDBTaskRepository(try AppDatabase.inMemory())
        try await tasks.replaceAll((first..<first + 1_000).map {
            Self.row("\($0)", at: Date(timeIntervalSince1970: Double($0) / 1000))
        })
        var misread = 0
        for stored in try await tasks.fetchAll() {
            let own = Date(timeIntervalSince1970: Double(try #require(Int(stored.id))) / 1000)
            if LWW.resolve(localUpdatedAt: stored.updatedAt, remoteClientUpdatedAt: own) != .noOp { misread += 1 }
        }
        #expect(misread == 0, "\(misread) stored stamps compared as another millisecond")
    }
}
