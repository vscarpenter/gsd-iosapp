import Testing
import Foundation
import GSDModel
import GSDStore
@testable import GSDSync
@testable import GSDWire

/// A PocketBase account that enforces the guarded task route (`pb_hooks/task-write-contract.js`):
/// `expected_version` is compared to the stored `client_updated_at` as a string, byte for byte.
/// A mismatch is 412, an unknown `data` key or an unchanged `client_updated_at` is 400, a missing
/// record is 404, and success is 204 with an empty body that stores the sent version.
actor GuardedServer: RequestExecuting {
    static let allowedKeys: Set<String> = [
        "owner", "task_id", "title", "description", "urgent", "important", "quadrant", "due_date",
        "completed", "completed_at", "recurrence", "tags", "subtasks", "dependencies",
        "notification_enabled", "notification_sent", "notify_before", "last_notification_at",
        "estimated_minutes", "time_spent", "time_entries", "snoozed_until", "saved_at", "focus_date",
        "focus_rank", "client_updated_at", "client_created_at", "device_id"]

    struct Patch: Sendable { let recordId: String; let expectedVersion: String; let clientUpdatedAt: String? }
    struct Delete: Sendable { let recordId: String; let expectedVersion: String }

    private var records: [String: [String: Any]] = [:]   // by record id
    private var pendingChange: (recordId: String, version: String)?
    private var pendingDrop: String?
    private(set) var patches: [Patch] = []
    private(set) var deletes: [Delete] = []
    private(set) var statuses: [Int] = []                 // every guarded answer, in order
    private(set) var collectionWrites: [String] = []      // writes that bypassed the guarded route

    /// `version: nil` lists the record with no `client_updated_at` at all.
    func put(recordId: String, taskId: String, version: String?, title: String = "remote") {
        var record: [String: Any] = ["id": recordId, "task_id": taskId, "owner": "u1", "title": title,
                                     "urgent": false, "important": false]
        if let version { record["client_updated_at"] = version }
        records[recordId] = record
    }
    /// After the next listing is served, rewrite the record's version, as a second device would.
    func changeAfterListing(recordId: String, version: String) { pendingChange = (recordId, version) }
    /// After the next listing is served, remove the record.
    func dropAfterListing(recordId: String) { pendingDrop = recordId }

    func version(of recordId: String) -> String? { records[recordId]?["client_updated_at"] as? String }
    func title(of recordId: String) -> String? { records[recordId]?["title"] as? String }
    func holds(_ recordId: String) -> Bool { records[recordId] != nil }

    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? ""
        if path.hasSuffix("/auth-refresh") {
            return reply(request, 200, #"{"token":"fresh","record":{"id":"u1","email":"e@x"}}"#)
        }
        if method == "GET" {
            let items = records.values.sorted { ($0["id"] as? String ?? "") < ($1["id"] as? String ?? "") }
            let page: [String: Any] = ["page": 1, "perPage": 200, "totalItems": items.count, "totalPages": 1, "items": items]
            let data = try JSONSerialization.data(withJSONObject: page)
            if let change = pendingChange { records[change.recordId]?["client_updated_at"] = change.version; pendingChange = nil }
            if let drop = pendingDrop { records[drop] = nil; pendingDrop = nil }
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        guard path.hasPrefix("/api/gsd/tasks/") else {
            collectionWrites.append("\(method) \(path)")
            if method == "POST", let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any] {
                var record = body; record["id"] = "rec_new"
                records["rec_new"] = record
                return reply(request, 200, String(decoding: try JSONSerialization.data(withJSONObject: record), as: UTF8.self))
            }
            return reply(request, 200, "{}")
        }
        let recordId = String(path.dropFirst("/api/gsd/tasks/".count))
        let body = try #require(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        let expected = body["expected_version"] as? String ?? ""
        let data = body["data"] as? [String: Any]
        if method == "PATCH" { patches.append(Patch(recordId: recordId, expectedVersion: expected,
                                                     clientUpdatedAt: data?["client_updated_at"] as? String)) }
        else { deletes.append(Delete(recordId: recordId, expectedVersion: expected)) }
        guard let stored = records[recordId] else { return answer(request, 404) }
        guard stored["client_updated_at"] as? String == expected else { return answer(request, 412) }
        if method == "DELETE" { records[recordId] = nil; return answer(request, 204) }
        guard let data, Set(data.keys).isSubset(of: Self.allowedKeys),
              let sent = data["client_updated_at"] as? String, sent != expected else { return answer(request, 400) }
        records[recordId] = stored.merging(data) { _, new in new }
        return answer(request, 204)
    }

    private func answer(_ request: URLRequest, _ status: Int) -> (Data, HTTPURLResponse) {
        statuses.append(status)
        return reply(request, status, status == 204 ? "" : #"{"message":"refused"}"#)
    }
    private func reply(_ request: URLRequest, _ status: Int, _ body: String) -> (Data, HTTPURLResponse) {
        (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

struct SyncEngineGuardedWriteTests {
    private static let listed = "2026-11-19T17:00:00.000Z"
    private static let now = WireDate.parse("2026-11-19T18:00:00.000Z")!

    private struct Rig {
        let server: GuardedServer
        let queue: GRDBSyncQueueRepository
        let engine: SyncEngine
    }
    private func rig(_ server: GuardedServer) throws -> Rig {
        let db = try AppDatabase.inMemory()
        let queue = GRDBSyncQueueRepository(db)
        let engine = SyncEngine(client: PocketBaseClient(baseURL: "https://guarded.test", executor: server),
                                tasks: GRDBTaskRepository(db), queue: queue,
                                cursor: SyncCursor(defaults: UserDefaults(suiteName: "guarded.\(UUID().uuidString)")!),
                                deviceId: "ios", tokenProvider: { "TOK" }, now: { Self.now }, throttleMs: 0)
        return Rig(server: server, queue: queue, engine: engine)
    }
    private func edit(_ title: String, at stamp: String) -> Task {
        Task(id: "a", title: title, urgent: false, important: false,
             createdAt: WireDate.parse("2026-11-01T00:00:00.000Z")!, updatedAt: WireDate.parse(stamp)!)
    }
    private func enqueue(_ rig: Rig, _ id: String, _ op: SyncQueueItem.Operation, at stamp: String, payload: Task? = nil) async throws {
        try await rig.queue.enqueue(SyncQueueItem(id: id, taskId: "a", operation: op,
            timestamp: Int(WireDate.parse(stamp)!.timeIntervalSince1970 * 1000), payload: payload))
    }
    private func seededServer(version: String? = listed) async -> GuardedServer {
        let server = GuardedServer(); await server.put(recordId: "rec1", taskId: "a", version: version); return server
    }

    @Test("an update writes through the guarded route with the listed version")
    func guardedUpdate() async throws {
        let rig = try rig(await seededServer())
        try await enqueue(rig, "q1", .update, at: "2026-11-19T17:30:00.000Z", payload: edit("edited", at: "2026-11-19T17:30:00.000Z"))
        let result = try await rig.engine.push(token: "TOK", owner: "u1")
        #expect(result.pushed == 1 && result.failed == 0)
        let patches = await rig.server.patches
        #expect(patches.count == 1 && patches.first?.expectedVersion == Self.listed)
        #expect(await rig.server.title(of: "rec1") == "edited")
        #expect(await rig.server.collectionWrites.isEmpty)
    }

    @Test("a version changed after the listing gets 412 and the row stays uncharged")
    func staleVersionIsNotCharged() async throws {
        let server = await seededServer()
        await server.changeAfterListing(recordId: "rec1", version: "2026-11-19T17:10:00.000Z")
        let rig = try rig(server)
        try await enqueue(rig, "q1", .update, at: "2026-11-19T17:30:00.000Z", payload: edit("edited", at: "2026-11-19T17:30:00.000Z"))
        let result = try await rig.engine.push(token: "TOK", owner: "u1")
        #expect(result.pushed == 0 && result.failed == 0)
        #expect(await server.statuses == [412])
        let row = try #require(try await rig.queue.pending().first)
        #expect(row.retryCount == 0 && row.lastAttemptAt == nil)
        #expect(await server.title(of: "rec1") == "remote")
    }

    @Test("an equal stamp sends one millisecond more")
    func equalStampBumps() async throws {
        let rig = try rig(await seededServer())
        try await enqueue(rig, "q1", .update, at: Self.listed, payload: edit("edited", at: Self.listed))
        let result = try await rig.engine.push(token: "TOK", owner: "u1")
        #expect(result.pushed == 1)
        #expect(await rig.server.patches.first?.clientUpdatedAt == "2026-11-19T17:00:00.001Z")
        #expect(await rig.server.version(of: "rec1") == "2026-11-19T17:00:00.001Z")
        #expect(try await rig.queue.pending().isEmpty)
    }

    @Test("two queued updates to one task both land in one push")
    func twoUpdatesOnePush() async throws {
        let rig = try rig(await seededServer())
        try await enqueue(rig, "q1", .update, at: "2026-11-19T17:20:00.000Z", payload: edit("first", at: "2026-11-19T17:20:00.000Z"))
        try await enqueue(rig, "q2", .update, at: "2026-11-19T17:40:00.000Z", payload: edit("second", at: "2026-11-19T17:40:00.000Z"))
        let result = try await rig.engine.push(token: "TOK", owner: "u1")
        #expect(result.pushed == 2 && result.failed == 0)
        #expect(await rig.server.statuses == [204, 204])
        let patches = await rig.server.patches
        #expect(patches.last?.expectedVersion == "2026-11-19T17:20:00.000Z")
        #expect(await rig.server.title(of: "rec1") == "second")
    }

    @Test("an update then a delete of one task both land in one push")
    func updateThenDelete() async throws {
        let rig = try rig(await seededServer())
        try await enqueue(rig, "q1", .update, at: "2026-11-19T17:20:00.000Z", payload: edit("first", at: "2026-11-19T17:20:00.000Z"))
        try await enqueue(rig, "q2", .delete, at: "2026-11-19T17:40:00.000Z")
        let result = try await rig.engine.push(token: "TOK", owner: "u1")
        #expect(result.pushed == 2 && result.failed == 0)
        #expect(await rig.server.statuses == [204, 204])
        #expect(await rig.server.holds("rec1") == false)
    }

    @Test("a far-future listed version is sent unclamped")
    func farFutureVersion() async throws {
        let far = "2099-01-01T00:00:00.000Z"
        let rig = try rig(await seededServer(version: far))
        try await enqueue(rig, "q1", .update, at: "2026-11-19T17:30:00.000Z", payload: edit("edited", at: "2026-11-19T17:30:00.000Z"))
        let result = try await rig.engine.push(token: "TOK", owner: "u1")
        #expect(result.pushed == 1)
        #expect(await rig.server.patches.first?.expectedVersion == far)
    }

    @Test("a non-canonical listed version is sent as listed")
    func nonCanonicalVersion() async throws {
        let odd = "2026-11-19 17:00:00Z"
        let rig = try rig(await seededServer(version: odd))
        try await enqueue(rig, "q1", .update, at: "2026-11-19T17:30:00.000Z", payload: edit("edited", at: "2026-11-19T17:30:00.000Z"))
        let result = try await rig.engine.push(token: "TOK", owner: "u1")
        #expect(result.pushed == 1)
        #expect(await rig.server.patches.first?.expectedVersion == odd)
    }

    @Test("a listed delete with no version is charged, not sent")
    func deleteWithoutVersion() async throws {
        let rig = try rig(await seededServer(version: nil))
        try await enqueue(rig, "q1", .delete, at: "2026-11-19T17:40:00.000Z")
        let result = try await rig.engine.push(token: "TOK", owner: "u1")
        #expect(result.pushed == 0 && result.failed == 1)
        #expect(try await rig.queue.pending().first?.retryCount == 1)
        #expect(await rig.server.deletes.isEmpty)
    }

    @Test("a 404 from the guarded route is charged")
    func missingRecordIsCharged() async throws {
        let server = await seededServer()
        await server.dropAfterListing(recordId: "rec1")
        let rig = try rig(server)
        try await enqueue(rig, "q1", .update, at: "2026-11-19T17:30:00.000Z", payload: edit("edited", at: "2026-11-19T17:30:00.000Z"))
        let result = try await rig.engine.push(token: "TOK", owner: "u1")
        #expect(result.pushed == 0 && result.failed == 1)
        #expect(await server.statuses == [404])
        #expect(try await rig.queue.pending().first?.retryCount == 1)
        #expect(await server.collectionWrites.isEmpty)
    }

    @Test("a delete that races an edit gets 412 and the record survives")
    func deleteRacingAnEdit() async throws {
        let server = await seededServer()
        await server.changeAfterListing(recordId: "rec1", version: "2026-11-19T17:10:00.000Z")
        let rig = try rig(server)
        try await enqueue(rig, "q1", .delete, at: "2026-11-19T17:40:00.000Z")
        // The listed 17:00 stamp is older than the queued delete, so push sends it; the server then holds 17:10.
        let result = try await rig.engine.push(token: "TOK", owner: "u1")
        #expect(result.pushed == 0 && result.failed == 0)
        #expect(await server.deletes.map(\.recordId) == ["rec1"])
        #expect(await server.deletes.first?.expectedVersion == Self.listed)
        #expect(await server.statuses == [412])
        #expect(await server.collectionWrites.isEmpty)
        #expect(await server.holds("rec1"))
        let row = try #require(try await rig.queue.pending().first)
        #expect(row.retryCount == 0 && row.lastAttemptAt == nil)
    }
}
