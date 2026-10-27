import Foundation
import Testing
import GSDModel
import GSDStore
@testable import GSDSync
@testable import GSDWire

/// One record another device saved. Honors the pull filter on `updated`, so a cursor
/// past the record hides it from an incremental pull; merges PATCH bodies like PocketBase.
private actor BackfillServer: RequestExecuting {
    static let stamp = "2026-10-26T23:29:40.274Z"
    private var record: [String: Any] = [
        "id": "record000000001", "task_id": "article", "owner": "u1", "title": "Read later",
        "description": "", "urgent": false, "important": true, "saved_at": stamp,
        "client_created_at": stamp, "client_updated_at": stamp,
        "updated": "2026-10-26 23:29:42.288Z", "device_id": "8340A040-OTHER",
    ]

    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let ok = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        if request.httpMethod == "PATCH", let body = request.httpBody,
           let fields = try JSONSerialization.jsonObject(with: body) as? [String: Any] {
            record.merge(fields) { _, new in new }
        }
        guard request.httpMethod == "GET" else { return (try JSONSerialization.data(withJSONObject: record), ok) }
        let items: [[String: Any]] = listed(by: request) ? [record] : []
        let page: [String: Any] = ["page": 1, "perPage": 200, "totalItems": items.count, "totalPages": 1, "items": items]
        return (try JSONSerialization.data(withJSONObject: page), ok)
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

    func savedAt() -> String { record["saved_at"] as? String ?? "" }
}

@MainActor
struct SyncEngineBackfillTests {
    nonisolated private static let token = "eyJhbGciOiJIUzI1NiJ9.eyJpZCI6InUxIiwiZXhwIjo5OTk5OTk5OTk5fQ.x"

    private struct Stack {
        let repo: GRDBTaskRepository
        let queue: GRDBSyncQueueRepository
        let cursor: SyncCursor
        let engine: SyncEngine
    }

    /// The row the build before Saved stored from the server record: the same version, minus the field.
    private func makeStack(_ server: BackfillServer, cursorPastTheRecord: Bool) throws -> Stack {
        let db = try AppDatabase.inMemory()
        let repo = GRDBTaskRepository(db)
        let queue = GRDBSyncQueueRepository(db)
        let defaults = UserDefaults(suiteName: "backfill-\(UUID().uuidString)")!
        if cursorPastTheRecord { defaults.set("2026-10-27 00:00:00.000Z", forKey: "gsd.sync.lastServerUpdated") }
        let cursor = SyncCursor(defaults: defaults)
        let engine = SyncEngine(client: PocketBaseClient(baseURL: "https://backfill.test", executor: server),
                                tasks: repo, queue: queue, cursor: cursor, deviceId: "ios",
                                tokenProvider: { Self.token }, now: { Date(timeIntervalSince1970: 1_800_000_000) },
                                throttleMs: 0)
        return Stack(repo: repo, queue: queue, cursor: cursor, engine: engine)
    }

    private func seedLocalCopy(_ repo: GRDBTaskRepository) async throws -> Date {
        let stamp = try #require(WireDate.parse(BackfillServer.stamp))
        try await repo.upsert(Task(id: "article", title: "Read later", urgent: false, important: true,
                                   createdAt: stamp, updatedAt: stamp))
        return stamp
    }

    private func ms(_ date: Date?) -> Int? { date.map { Int(($0.timeIntervalSince1970 * 1000).rounded()) } }

    @Test func syncBackfillsASameVersionFieldOnceWithoutSeedingTheQueue() async throws {
        let server = BackfillServer()
        let stack = try makeStack(server, cursorPastTheRecord: true)
        let stamp = try await seedLocalCopy(stack.repo)

        let first = await stack.engine.sync(trigger: .launch)
        #expect(first.error == nil && first.pulled == 1)
        #expect(ms(try await stack.repo.fetch(id: "article")?.savedAt) == ms(stamp))
        #expect(try await stack.queue.all().isEmpty)                  // no first-sign-in seed
        #expect(await server.savedAt() == BackfillServer.stamp)        // the server copy kept its placement

        let second = await stack.engine.sync(trigger: .periodic)
        #expect(second.error == nil && second.pulled == 0)
        #expect(!stack.cursor.needsBackfill())
    }

    @Test func pullMergesASameVersionRecordOnlyWhileBackfilling() async throws {
        let server = BackfillServer()
        let stack = try makeStack(server, cursorPastTheRecord: false)
        _ = try await seedLocalCopy(stack.repo)
        let epoch = "1970-01-01 00:00:00.000Z"

        let plain = try await stack.engine.pull(token: Self.token, since: epoch)
        #expect(plain.applied == 0)
        #expect(try await stack.repo.fetch(id: "article")?.isSaved == false)

        let backfill = try await stack.engine.pull(token: Self.token, since: epoch, mergeSameVersion: true)
        #expect(backfill.applied == 1 && backfill.conflicts == 0)      // a same-version merge is not a conflict
        #expect(try await stack.repo.fetch(id: "article")?.isSaved == true)
    }
}
