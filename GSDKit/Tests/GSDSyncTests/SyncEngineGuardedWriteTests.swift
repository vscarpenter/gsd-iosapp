import Testing
import Foundation
import GSDModel
import GSDStore
@testable import GSDSync
@testable import GSDWire

/// A PocketBase account that enforces the guarded task route (`pb_hooks/task-write-contract.js`):
/// `expected_version` is compared to the stored `client_updated_at` as a string, byte for byte.
/// A mismatch is 412. A missing or overlong `expected_version`, an unknown `data` key, or an unchanged
/// `client_updated_at` is 400. A missing record is 404, and success is 204 with an empty body that
/// stores the sent version.
actor GuardedServer: RequestExecuting {
    static let allowedKeys: Set<String> = [
        "owner", "task_id", "title", "description", "urgent", "important", "quadrant", "due_date",
        "completed", "completed_at", "recurrence", "tags", "subtasks", "dependencies",
        "notification_enabled", "notification_sent", "notify_before", "last_notification_at",
        "estimated_minutes", "time_spent", "time_entries", "snoozed_until", "saved_at", "focus_date",
        "focus_rank", "client_updated_at", "client_created_at", "device_id"]

    struct Patch: Sendable { let recordId: String; let expectedVersion: String; let clientUpdatedAt: String?; let notifyBefore: Int? }
    struct Delete: Sendable { let recordId: String; let expectedVersion: String }

    private var records: [String: [String: Any]] = [:]   // by record id
    private var pendingChange: (recordId: String, version: String)?
    private var pendingDrop: String?
    private(set) var patches: [Patch] = []
    private(set) var deletes: [Delete] = []
    private(set) var statuses: [Int] = []                 // every guarded answer, in order
    private(set) var collectionWrites: [String] = []      // writes that bypassed the guarded route
    private(set) var postedVersions: [String] = []        // `client_updated_at` of every create
    private var duringPatch: (@Sendable () -> Void)?
    private var afterPatch: (recordId: String, version: String, deviceId: String)?
    private var loseNextPatchResponse = false

    /// `version: nil` lists the record with no `client_updated_at` at all.
    func put(recordId: String, taskId: String, version: String?, title: String = "remote", deviceId: String? = nil) {
        var record: [String: Any] = ["id": recordId, "task_id": taskId, "owner": "u1", "title": title,
                                     "urgent": false, "important": false]
        if let deviceId { record["device_id"] = deviceId }
        if let version { record["client_updated_at"] = version }
        records[recordId] = record
    }
    /// After the next listing is served, rewrite the record's version, as a second device would.
    func changeAfterListing(recordId: String, version: String) { pendingChange = (recordId, version) }
    /// After the next listing is served, remove the record.
    func dropAfterListing(recordId: String) { pendingDrop = recordId }

    /// Runs as each guarded PATCH arrives, as a sign-out that lands during the request would.
    func onPatch(_ action: @escaping @Sendable () -> Void) { duringPatch = action }

    /// After the next PATCH lands, another device rewrites the record.
    func changeAfterNextPatch(recordId: String, version: String, deviceId: String) { afterPatch = (recordId, version, deviceId) }
    /// The next PATCH is applied, but the client sees a 502 instead of the 204.
    func loseResponseOfNextPatch() { loseNextPatchResponse = true }

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
                if let sent = body["client_updated_at"] as? String { postedVersions.append(sent) }
                records["rec_new"] = record
                return reply(request, 200, String(decoding: try JSONSerialization.data(withJSONObject: record), as: UTF8.self))
            }
            return reply(request, 200, "{}")
        }
        let recordId = String(path.dropFirst("/api/gsd/tasks/".count))
        let body = try #require(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        let expected = body["expected_version"] as? String ?? ""
        let data = body["data"] as? [String: Any]
        if method == "PATCH" { duringPatch?() }
        if method == "PATCH" { patches.append(Patch(recordId: recordId, expectedVersion: expected,
                                                     clientUpdatedAt: data?["client_updated_at"] as? String,
                                                     notifyBefore: data?["notify_before"] as? Int)) }
        else { deletes.append(Delete(recordId: recordId, expectedVersion: expected)) }
        // The hook checks the version's shape before it looks the record up. JavaScript's `length` counts UTF-16 units.
        guard body["expected_version"] is String, expected.utf16.count <= 64 else { return answer(request, 400) }
        guard let stored = records[recordId] else { return answer(request, 404) }
        // `record.getString` reads an absent version as "".
        guard (stored["client_updated_at"] as? String ?? "") == expected else { return answer(request, 412) }
        if method == "DELETE" { records[recordId] = nil; return answer(request, 204) }
        guard let data, Set(data.keys).isSubset(of: Self.allowedKeys),
              let sent = data["client_updated_at"] as? String, sent != expected else { return answer(request, 400) }
        records[recordId] = stored.merging(data) { _, new in new }
        if let change = afterPatch {
            records[change.recordId]?["client_updated_at"] = change.version
            records[change.recordId]?["device_id"] = change.deviceId
            afterPatch = nil
        }
        if loseNextPatchResponse { loseNextPatchResponse = false; return answer(request, 502) }   // a gateway fault after the write applied
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
        let tasks: GRDBTaskRepository
        let engine: SyncEngine
    }
    private func rig(_ server: GuardedServer) throws -> Rig {
        let db = try AppDatabase.inMemory()
        let queue = GRDBSyncQueueRepository(db)
        let tasks = GRDBTaskRepository(db)
        let engine = SyncEngine(client: PocketBaseClient(baseURL: "https://guarded.test", executor: server),
                                tasks: tasks, queue: queue,
                                cursor: SyncCursor(defaults: UserDefaults(suiteName: "guarded.\(UUID().uuidString)")!),
                                deviceId: "ios", tokenProvider: { "TOK" }, now: { Self.now }, throttleMs: 0)
        return Rig(server: server, queue: queue, tasks: tasks, engine: engine)
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

    // MARK: R15, a delete over an unusable listed version is sent

    @Test("R15: a Trash delete over a listed record with no version is sent with an empty expected version")
    func deleteOverAMissingVersionIsSentWithAnEmptyExpectedVersion() async throws {
        let rig = try rig(await seededServer(version: nil))
        try await enqueue(rig, "q1", .delete, at: "2026-11-19T17:40:00.000Z")   // a Trash delete carries no payload
        let result = try await rig.engine.push(token: "TOK", owner: "u1")
        #expect(result.pushed == 1 && result.failed == 0)
        #expect(await rig.server.deletes.map(\.expectedVersion) == [""])
        #expect(await rig.server.statuses == [204])
        #expect(await rig.server.holds("rec1") == false)
        #expect(try await rig.queue.all().isEmpty)
    }

    @Test("R15: a delete over a garbled listed version sends the raw value")
    func deleteOverAGarbledVersionSendsTheRawValue() async throws {
        let rig = try rig(await seededServer(version: "not-a-date"))
        try await enqueue(rig, "q1", .delete, at: "2026-11-19T17:40:00.000Z")
        let result = try await rig.engine.push(token: "TOK", owner: "u1")
        #expect(result.pushed == 1 && result.failed == 0)
        #expect(await rig.server.deletes.map(\.expectedVersion) == ["not-a-date"])
        #expect(await rig.server.holds("rec1") == false)
        #expect(try await rig.queue.all().isEmpty)
    }

    @Test("R15: an update over a listed record with no version is still refused and charged")
    func upsertOverAMissingVersionIsStillRefusedAndCharged() async throws {
        let rig = try rig(await seededServer(version: nil))
        try await enqueue(rig, "q1", .update, at: "2026-11-19T17:30:00.000Z", payload: edit("edited", at: "2026-11-19T17:30:00.000Z"))
        let result = try await rig.engine.push(token: "TOK", owner: "u1")
        #expect(result.pushed == 0 && result.failed == 1)
        #expect(await rig.server.patches.isEmpty)
        #expect(await rig.server.collectionWrites.isEmpty)
        #expect(try await rig.queue.pending().first?.retryCount == 1)
    }

    @Test("R15: a delete over an overlong version gets 400, is charged, and the push goes on")
    func deleteOverAnOverlongVersionIsChargedAndThePushContinues() async throws {
        let overlong = String(repeating: "9", count: 65)
        let server = await seededServer(version: overlong)
        await server.put(recordId: "rec2", taskId: "b", version: Self.listed)
        let rig = try rig(server)
        try await enqueue(rig, "q1", .delete, at: "2026-11-19T17:40:00.000Z")
        let other = Task(id: "b", title: "edited b", urgent: false, important: false,
                         createdAt: WireDate.parse("2026-11-01T00:00:00.000Z")!, updatedAt: WireDate.parse("2026-11-19T17:41:00.000Z")!)
        try await rig.queue.enqueue(SyncQueueItem(id: "q2", taskId: "b", operation: .update,
            timestamp: Int(other.updatedAt.timeIntervalSince1970 * 1000), payload: other))
        let result = try await rig.engine.push(token: "TOK", owner: "u1")
        #expect(result.pushed == 1 && result.failed == 1)
        #expect(await server.deletes.map(\.expectedVersion) == [overlong])
        #expect(await server.statuses == [400, 204])
        #expect(await server.holds("rec1"))
        #expect(await server.title(of: "rec2") == "edited b")
        let row = try #require(try await rig.queue.pending().first)
        #expect(row.id == "q1" && row.retryCount == 1)
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

    @Test("a 412 on one row leaves the next row to land")
    func staleRowDoesNotStarveTheNext() async throws {
        let server = await seededServer()
        await server.put(recordId: "rec2", taskId: "b", version: Self.listed)
        await server.changeAfterListing(recordId: "rec1", version: "2026-11-19T17:10:00.000Z")
        let rig = try rig(server)
        try await enqueue(rig, "q1", .update, at: "2026-11-19T17:30:00.000Z", payload: edit("edited a", at: "2026-11-19T17:30:00.000Z"))
        let other = Task(id: "b", title: "edited b", urgent: false, important: false,
                         createdAt: WireDate.parse("2026-11-01T00:00:00.000Z")!, updatedAt: WireDate.parse("2026-11-19T17:31:00.000Z")!)
        try await rig.queue.enqueue(SyncQueueItem(id: "q2", taskId: "b", operation: .update,
            timestamp: Int(other.updatedAt.timeIntervalSince1970 * 1000), payload: other))
        let result = try await rig.engine.push(token: "TOK", owner: "u1")
        #expect(result.pushed == 1 && result.failed == 0)
        #expect(await server.statuses == [412, 204])
        #expect(try await rig.queue.pending().map(\.id) == ["q1"])
        #expect(await server.title(of: "rec2") == "edited b")
    }

    @Test("an update after a create in one push expects the version the create stored")
    func updateAfterCreateExpectsTheCreatedVersion() async throws {
        let server = GuardedServer()
        let rig = try rig(server)
        try await enqueue(rig, "q1", .create, at: "2026-11-19T17:20:00.000Z", payload: edit("first", at: "2026-11-19T17:20:00.000Z"))
        try await enqueue(rig, "q2", .update, at: "2026-11-19T17:40:00.000Z", payload: edit("second", at: "2026-11-19T17:40:00.000Z"))
        let result = try await rig.engine.push(token: "TOK", owner: "u1")
        #expect(result.pushed == 2 && result.failed == 0)
        let posted = try #require(await server.postedVersions.first)
        #expect(await server.patches.map(\.expectedVersion) == [posted])
        #expect(await server.statuses == [204])
        #expect(await server.title(of: "rec_new") == "second")
    }

    // MARK: Restamp after a bumped write

    private static let bumped = "2026-11-19T17:00:00.001Z"

    private func rowStamp(_ rig: Rig) async throws -> String? {
        try await rig.tasks.fetch(id: "a").map { WireDate.format($0.updatedAt) }
    }
    /// Seeds the local row and queues an update whose stamp equals the listed one, so the push bumps it.
    private func seedBumpedUpdate(_ rig: Rig) async throws {
        try await rig.tasks.upsert(edit("edited", at: Self.listed))
        try await enqueue(rig, "q1", .update, at: Self.listed, payload: edit("edited", at: Self.listed))
    }

    @Test("AC1: a bumped write leaves the local row at the sent stamp and queues nothing")
    func bumpedWriteRestampsTheRow() async throws {
        let rig = try rig(await seededServer())
        try await seedBumpedUpdate(rig)
        _ = try await rig.engine.push(token: "TOK", owner: "u1")
        #expect(try await rowStamp(rig) == Self.bumped)
        #expect(try await rig.queue.pending().isEmpty)
        #expect(try await rig.tasks.fetch(id: "a")?.title == "edited")
    }

    @Test("AC2: an archive queued after a bumped push deletes the task")
    func archiveAfterBumpedPush() async throws {
        let rig = try rig(await seededServer())
        try await seedBumpedUpdate(rig)
        _ = try await rig.engine.push(token: "TOK", owner: "u1")
        let archived = try #require(try await rig.tasks.fetch(id: "a"))   // TaskStore.archive queues the row it fetches
        try await enqueue(rig, "q2", .delete, at: "2026-11-19T17:45:00.000Z", payload: archived)
        let result = try await rig.engine.push(token: "TOK", owner: "u1")
        #expect(result.pushed == 1 && result.failed == 0)
        #expect(await rig.server.deletes.map(\.expectedVersion) == [Self.bumped])
        #expect(await rig.server.holds("rec1") == false)
    }

    @Test("AC3: a bumped update and an archive delete in one push both land")
    func bumpedUpdateThenArchiveDelete() async throws {
        let rig = try rig(await seededServer())
        try await seedBumpedUpdate(rig)
        try await enqueue(rig, "q2", .delete, at: "2026-11-19T17:45:00.000Z", payload: edit("edited", at: Self.listed))
        let result = try await rig.engine.push(token: "TOK", owner: "u1")
        #expect(result.pushed == 2 && result.failed == 0)
        #expect(await rig.server.statuses == [204, 204])
        #expect(await rig.server.deletes.map(\.expectedVersion) == [Self.bumped])
        #expect(await rig.server.holds("rec1") == false)
    }

    @Test("AC4: a local edit made after the update was queued is not overwritten")
    func newerLocalEditSurvives() async throws {
        let rig = try rig(await seededServer())
        try await rig.tasks.upsert(edit("newer local edit", at: "2026-11-19T17:45:00.000Z"))
        try await enqueue(rig, "q1", .update, at: Self.listed, payload: edit("edited", at: Self.listed))
        _ = try await rig.engine.push(token: "TOK", owner: "u1")
        #expect(await rig.server.patches.first?.clientUpdatedAt == Self.bumped)
        #expect(try await rowStamp(rig) == "2026-11-19T17:45:00.000Z")
        #expect(try await rig.tasks.fetch(id: "a")?.title == "newer local edit")
    }

    @Test("AC5: a session that ends during the PATCH leaves the local row untouched")
    func sessionEndsDuringThePatch() async throws {
        func jwt(_ id: String) -> String {
            let payload = Data(#"{"id":"\#(id)","exp":9999999999}"#.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            return "h.\(payload).s"
        }
        final class Session: @unchecked Sendable { var token: String? }
        let session = Session(); session.token = jwt("u1")
        let server = await seededServer()
        await server.onPatch { session.token = nil }
        let db = try AppDatabase.inMemory()
        let tasks = GRDBTaskRepository(db)
        let queue = GRDBSyncQueueRepository(db)
        let engine = SyncEngine(client: PocketBaseClient(baseURL: "https://guarded.test", executor: server),
                                tasks: tasks, queue: queue, tombstones: GRDBTombstoneRepository(db),
                                cursor: SyncCursor(defaults: UserDefaults(suiteName: "guarded.\(UUID().uuidString)")!),
                                deviceId: "ios", tokenProvider: { "TOK" }, rawToken: { session.token },
                                now: { Self.now }, throttleMs: 0)
        try await tasks.upsert(edit("edited", at: Self.listed))
        try await queue.enqueue(SyncQueueItem(id: "q1", taskId: "a", operation: .update,
            timestamp: Int(WireDate.parse(Self.listed)!.timeIntervalSince1970 * 1000), payload: edit("edited", at: Self.listed)))
        await #expect(throws: StaleSyncSession.self) { try await engine.push(token: "TOK", owner: "u1") }
        #expect(try await tasks.fetch(id: "a").map { WireDate.format($0.updatedAt) } == Self.listed)
        let row = try #require(try await queue.pending().first)
        #expect(row.id == "q1" && row.retryCount == 0 && row.lastAttemptAt == nil && row.status == .pending)
    }

    @Test("AC6: a write that was not bumped leaves the local row's stamp alone")
    func unbumpedWriteLeavesTheStamp() async throws {
        let rig = try rig(await seededServer())
        try await rig.tasks.upsert(edit("edited", at: "2026-11-19T17:30:00.000Z"))
        try await enqueue(rig, "q1", .update, at: "2026-11-19T17:30:00.000Z", payload: edit("edited", at: "2026-11-19T17:30:00.000Z"))
        _ = try await rig.engine.push(token: "TOK", owner: "u1")
        #expect(try await rowStamp(rig) == "2026-11-19T17:30:00.000Z")
    }

    @Test("AC7: the next pull after a bumped write applies nothing and reports no conflict")
    func nextPullIsQuiet() async throws {
        let rig = try rig(await seededServer())
        try await seedBumpedUpdate(rig)
        _ = try await rig.engine.push(token: "TOK", owner: "u1")
        let pulled = try await rig.engine.pull(token: "TOK", since: "1970-01-01 00:00:00.000Z")
        #expect(pulled.applied == 0 && pulled.conflicts == 0)
    }

    // MARK: Own bump across pushes (F3), rounding, and both halves of F2

    @Test("AC9: a task archived while its bumped PATCH was in flight is deleted by the next push")
    func archivedDuringTheBumpedPatch() async throws {
        let rig = try rig(await seededServer())
        // The archive removed the row before the 204, so there is nothing to restamp.
        try await enqueue(rig, "q1", .update, at: Self.listed, payload: edit("edited", at: Self.listed))
        _ = try await rig.engine.push(token: "TOK", owner: "u1")
        #expect(await rig.server.version(of: "rec1") == Self.bumped)
        try await enqueue(rig, "q2", .delete, at: "2026-11-19T17:45:00.000Z", payload: edit("edited", at: Self.listed))
        let result = try await rig.engine.push(token: "TOK", owner: "u1")
        #expect(result.pushed == 1 && result.failed == 0)
        #expect(await rig.server.deletes.map(\.expectedVersion) == [Self.bumped])
        #expect(await rig.server.holds("rec1") == false)
    }

    @Test("AC10: the PATCH landed, its response was lost, then the task was archived")
    @MainActor func lostResponseThenArchive() async throws {
        let server = await seededServer()
        await server.loseResponseOfNextPatch()
        let rig = try storeRig(server, clock: Clock(Self.now))
        let row = edit("edited", at: Self.listed)
        try await rig.tasks.upsert(row)
        try await rig.queue.enqueue(SyncQueueItem(id: "q1", taskId: "a", operation: .update,
            timestamp: Int(row.updatedAt.timeIntervalSince1970 * 1000), payload: row))
        _ = try? await rig.engine.push(token: "TOK", owner: "u1")
        #expect(await server.version(of: "rec1") == Self.bumped)
        #expect(try await rig.queue.pending().map(\.id) == ["q1"])   // charged, kept
        try await rig.store.archive(row)
        // The archive clears the task's queued writes, so only the delete is left.
        let queued = try await rig.queue.all()
        #expect(queued.count == 1 && queued.first?.operation == .delete)
        _ = try await rig.engine.push(token: "TOK", owner: "u1")
        #expect(await server.deletes.map(\.expectedVersion) == [Self.bumped])
        #expect(await server.holds("rec1") == false)
        #expect(try await rig.queue.all().isEmpty)
    }

    @Test("AC11: another device's edit at exactly the bumped stamp keeps the delete stale")
    func otherDeviceAtTheBumpedStamp() async throws {
        let server = GuardedServer()
        await server.put(recordId: "rec1", taskId: "a", version: Self.bumped, deviceId: "other-device")
        let rig = try rig(server)
        try await enqueue(rig, "q1", .delete, at: "2026-11-19T17:45:00.000Z", payload: edit("edited", at: Self.listed))
        let result = try await rig.engine.push(token: "TOK", owner: "u1")
        #expect(result.pushed == 0 && result.failed == 0)
        #expect(await server.deletes.isEmpty)
        #expect(try await rig.queue.pending().isEmpty)
        #expect(await server.holds("rec1"))
    }

    @Test("F2 create half: a create then an archive delete with an older payload both land")
    func createThenArchiveDelete() async throws {
        let server = GuardedServer()
        let rig = try rig(server)
        try await enqueue(rig, "q1", .create, at: "2026-11-19T17:20:00.000Z", payload: edit("first", at: "2026-11-19T17:20:00.000Z"))
        try await enqueue(rig, "q2", .delete, at: "2026-11-19T17:40:00.000Z", payload: edit("first", at: "2026-11-19T17:00:00.000Z"))
        let result = try await rig.engine.push(token: "TOK", owner: "u1")
        #expect(result.pushed == 2 && result.failed == 0)
        #expect(await server.statuses == [204])
        #expect(await server.holds("rec_new") == false)
    }

    @Test("F2 412 protection: another device writes between the PATCH and the DELETE")
    func editBetweenPatchAndDelete() async throws {
        let server = await seededServer()
        await server.changeAfterNextPatch(recordId: "rec1", version: "2026-11-19T17:10:00.000Z", deviceId: "other-device")
        let rig = try rig(server)
        try await seedBumpedUpdate(rig)
        try await enqueue(rig, "q2", .delete, at: "2026-11-19T17:45:00.000Z", payload: edit("edited", at: Self.listed))
        let result = try await rig.engine.push(token: "TOK", owner: "u1")
        #expect(result.pushed == 1 && result.failed == 0)
        #expect(await server.statuses == [204, 412])
        #expect(await server.holds("rec1"))
        let row = try #require(try await rig.queue.pending().first)
        #expect(row.id == "q2" && row.retryCount == 0 && row.lastAttemptAt == nil)
    }

    @Test("AC1 and AC2 hold for stamps a truncating comparison would miss",
          arguments: ["2026-11-19T17:00:00.002Z", "2026-11-19T17:00:00.009Z", "2026-11-19T17:00:00.015Z"])
    func restampAtAnyMillisecond(stamp: String) async throws {
        let bumpedStamp = LWW.guardedVersion(outgoing: stamp, expected: stamp)
        let server = GuardedServer()
        await server.put(recordId: "rec1", taskId: "a", version: stamp)
        let rig = try rig(server)
        try await rig.tasks.upsert(edit("edited", at: stamp))
        try await enqueue(rig, "q1", .update, at: stamp, payload: edit("edited", at: stamp))
        _ = try await rig.engine.push(token: "TOK", owner: "u1")
        #expect(try await rowStamp(rig) == bumpedStamp)
        let archived = try #require(try await rig.tasks.fetch(id: "a"))
        try await enqueue(rig, "q2", .delete, at: "2026-11-19T17:45:00.000Z", payload: archived)
        _ = try await rig.engine.push(token: "TOK", owner: "u1")
        #expect(await server.deletes.map(\.expectedVersion) == [bumpedStamp])
        #expect(await server.holds("rec1") == false)
    }

    // MARK: F4, never re-create a task this device no longer holds

    private final class Clock: @unchecked Sendable { var date: Date; init(_ date: Date) { self.date = date } }

    /// An engine and a real `TaskStore` over one database, with a clock the test can move.
    @MainActor private func storeRig(_ server: GuardedServer, clock: Clock) throws -> (store: TaskStore, tasks: GRDBTaskRepository, queue: GRDBSyncQueueRepository, engine: SyncEngine) {
        let db = try AppDatabase.inMemory()
        let queue = GRDBSyncQueueRepository(db)
        let tasks = GRDBTaskRepository(db)
        let store = TaskStore(repository: tasks, smartViewRepository: GRDBSmartViewRepository(db),
                              archiveRepository: GRDBArchiveRepository(db), trashRepository: GRDBTrashRepository(db),
                              defaults: UserDefaults(suiteName: "guarded.\(UUID().uuidString)")!,
                              clock: { WireDate.parse("2026-11-19T17:45:00.000Z")! }, syncQueue: queue)
        let engine = SyncEngine(client: PocketBaseClient(baseURL: "https://guarded.test", executor: server),
                                tasks: tasks, queue: queue,
                                cursor: SyncCursor(defaults: UserDefaults(suiteName: "guarded.\(UUID().uuidString)")!),
                                deviceId: "ios", tokenProvider: { "TOK" }, now: { clock.date }, throttleMs: 0)
        return (store, tasks, queue, engine)
    }

    /// A charged update row (lost 204), then `leave` takes the task out of the live table, the delete
    /// lands in the next push, and the update row comes due once its backoff passes.
    @MainActor private func chargedUpdateThenLeave(_ leave: (TaskStore, Task) async throws -> Void) async throws -> (server: GuardedServer, queue: GRDBSyncQueueRepository) {
        let server = await seededServer()
        await server.loseResponseOfNextPatch()
        let clock = Clock(Self.now)
        let rig = try storeRig(server, clock: clock)
        let row = edit("edited", at: Self.listed)
        try await rig.tasks.upsert(row)
        try await rig.queue.enqueue(SyncQueueItem(id: "q1", taskId: "a", operation: .update,
            timestamp: Int(row.updatedAt.timeIntervalSince1970 * 1000), payload: row))
        _ = try? await rig.engine.push(token: "TOK", owner: "u1")
        let charged = try #require(try await rig.queue.pending().first)
        #expect(charged.id == "q1" && charged.retryCount == 1)
        try await leave(rig.store, row)
        _ = try await rig.engine.push(token: "TOK", owner: "u1")   // the update row is in backoff; the delete lands
        #expect(await server.holds("rec1") == false)
        clock.date = Self.now.addingTimeInterval(600)
        _ = try await rig.engine.push(token: "TOK", owner: "u1")   // the update row is due, and the task is unlisted
        return (server, rig.queue)
    }

    @Test("AC13: a charged update never re-creates a task archived afterwards")
    @MainActor func chargedUpdateAfterArchive() async throws {
        let (server, queue) = try await chargedUpdateThenLeave { store, row in try await store.archive(row) }
        #expect(await server.collectionWrites.isEmpty)
        #expect(await server.holds("rec_new") == false)
        #expect(try await queue.pending().isEmpty)
    }

    @Test("AC13: a charged update never re-creates a task moved to Trash afterwards")
    @MainActor func chargedUpdateAfterTrash() async throws {
        let (server, queue) = try await chargedUpdateThenLeave { store, row in try await store.delete(row) }
        #expect(await server.collectionWrites.isEmpty)
        #expect(await server.holds("rec_new") == false)
        #expect(try await queue.pending().isEmpty)
    }

    @Test("an update for a live task the server doesn't list still creates it")
    func liveUnlistedUpdateCreates() async throws {
        let server = GuardedServer()
        let rig = try rig(server)
        try await rig.tasks.upsert(edit("edited", at: "2026-11-19T17:30:00.000Z"))
        try await enqueue(rig, "q1", .update, at: "2026-11-19T17:30:00.000Z", payload: edit("edited", at: "2026-11-19T17:30:00.000Z"))
        let result = try await rig.engine.push(token: "TOK", owner: "u1")
        #expect(result.pushed == 1 && result.failed == 0)
        #expect(await server.collectionWrites == ["POST /api/collections/tasks/records"])
        #expect(await server.holds("rec_new"))
    }

    // MARK: Clock skew (AC14) and the exact shape F3 matches (AC15)

    private static func jwt(_ id: String) -> String {
        let payload = Data(#"{"id":"\#(id)","exp":9999999999}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "h.\(payload).s"
    }

    /// A task archived here at 17:45 whose server copy is stamped by a writer whose clock runs two
    /// minutes ahead of this device's. A full sync (pull, push, reconcile) runs against a real archive.
    @MainActor private func skewedSync(server: GuardedServer, queuedUpdate: Bool,
                                       storeClock: (@Sendable () -> Date)? = nil) async throws
        -> (tasks: GRDBTaskRepository, queue: GRDBSyncQueueRepository) {
        let buried = WireDate.parse("2026-11-19T17:45:00.000Z")!
        let db = try AppDatabase.inMemory()
        let queue = GRDBSyncQueueRepository(db)
        let tasks = GRDBTaskRepository(db)
        let store = TaskStore(repository: tasks, smartViewRepository: GRDBSmartViewRepository(db),
                              archiveRepository: GRDBArchiveRepository(db, now: { buried }),
                              trashRepository: GRDBTrashRepository(db, now: { buried }),
                              defaults: UserDefaults(suiteName: "guarded.\(UUID().uuidString)")!,
                              clock: storeClock ?? { buried }, syncQueue: queue)
        let cursor = SyncCursor(defaults: UserDefaults(suiteName: "guarded.\(UUID().uuidString)")!)
        cursor.advance(maxApplied: Date(timeIntervalSince1970: 1_000)); cursor.markBackfilled()
        let token = Self.jwt("u1")
        let engine = SyncEngine(client: PocketBaseClient(baseURL: "https://guarded.test", executor: server),
                                tasks: tasks, queue: queue, tombstones: GRDBTombstoneRepository(db), cursor: cursor,
                                deviceId: "ios", tokenProvider: { token }, rawToken: { token },
                                now: { Self.now }, throttleMs: 0)
        let ahead = "2026-11-19T18:02:00.000Z"
        let row = edit("edited", at: ahead)
        try await tasks.upsert(row)
        if queuedUpdate {
            // Built by hand: `store.archive` clears the task's queued update, and F2 needs the PATCH to run.
            try await GRDBArchiveRepository(db).archive(row, at: buried)
            let archivedMs = Int(buried.timeIntervalSince1970 * 1000)
            try await queue.enqueue(SyncQueueItem(id: "q1", taskId: "a", operation: .update,
                timestamp: archivedMs - 60_000, payload: row))
            try await queue.enqueue(SyncQueueItem(id: "q2", taskId: "a", operation: .delete,
                timestamp: archivedMs, payload: row))
        } else {
            try await store.archive(row)
        }
        let result = await engine.sync(trigger: .manual)
        #expect(result.error == nil)
        return (tasks, queue)
    }

    @Test("AC14: a skewed writer's equal-stamp update and archive delete in one push lose nothing")
    @MainActor func skewWithinOnePush() async throws {
        let server = GuardedServer()
        await server.put(recordId: "rec1", taskId: "a", version: "2026-11-19T18:02:00.000Z", deviceId: "other-device")
        let (tasks, _) = try await skewedSync(server: server, queuedUpdate: true)
        #expect(await server.patches.count == 1)   // the bumped PATCH ran, so F2 had a write to recognize
        #expect(await server.holds("rec1"))
        #expect(await server.deletes.isEmpty)
        #expect(try await tasks.fetch(id: "a") != nil)
    }

    @Test("AC14: a skewed writer's own bump seen in a later push loses nothing")
    @MainActor func skewAcrossPushes() async throws {
        let server = GuardedServer()
        await server.put(recordId: "rec1", taskId: "a", version: "2026-11-19T18:02:00.001Z", deviceId: "ios")
        let (tasks, _) = try await skewedSync(server: server, queuedUpdate: false)
        #expect(await server.holds("rec1"))
        #expect(await server.deletes.isEmpty)
        #expect(try await tasks.fetch(id: "a") != nil)
    }

    @Test("AC15: F3 matches only this device at exactly one millisecond past the archived version",
          arguments: [("2026-11-19T17:00:00.002Z", "ios"), (bumped, nil), (bumped, "")] as [(String, String?)])
    func ownBumpMatchesOnlyTheExactShape(version: String, device: String?) async throws {
        let server = GuardedServer()
        await server.put(recordId: "rec1", taskId: "a", version: version, deviceId: device)
        let rig = try rig(server)
        try await enqueue(rig, "q1", .delete, at: "2026-11-19T17:45:00.000Z", payload: edit("edited", at: Self.listed))
        let result = try await rig.engine.push(token: "TOK", owner: "u1")
        #expect(result.pushed == 0 && result.failed == 0)
        #expect(await server.deletes.isEmpty)
        #expect(try await rig.queue.pending().isEmpty)
        #expect(await server.holds("rec1"))
    }

    private final class Ticks: @unchecked Sendable {
        var next: Date; let step: TimeInterval
        init(from start: Date, step: TimeInterval) { next = start; self.step = step }
        func read() -> Date { defer { next = next.addingTimeInterval(step) }; return next }
    }

    @Test("an archive reads the clock once: a bump landing between two readings loses nothing")
    @MainActor func archiveUsesOneClockReading() async throws {
        let server = GuardedServer()
        await server.put(recordId: "rec1", taskId: "a", version: "2026-11-19T18:02:00.001Z", deviceId: "ios")
        let ticks = Ticks(from: WireDate.parse("2026-11-19T18:02:00.000Z")!, step: 0.002)
        let (tasks, _) = try await skewedSync(server: server, queuedUpdate: false, storeClock: { ticks.read() })
        #expect(await server.holds("rec1"))
        #expect(await server.deletes.isEmpty)
        #expect(try await tasks.fetch(id: "a") != nil)
    }

    @Test("D-10: a listed record with no local row and a null payload carries the device default")
    func listedGoneRowPushesTheDefault() async throws {
        let server = await seededServer()
        let db = try AppDatabase.inMemory()
        let queue = GRDBSyncQueueRepository(db)
        let engine = SyncEngine(client: PocketBaseClient(baseURL: "https://guarded.test", executor: server),
                                tasks: GRDBTaskRepository(db), queue: queue,
                                cursor: SyncCursor(defaults: UserDefaults(suiteName: "guarded.\(UUID().uuidString)")!),
                                deviceId: "ios", tokenProvider: { "TOK" }, now: { Self.now }, throttleMs: 0,
                                defaultReminder: { 20 })
        var payload = edit("edited", at: "2026-11-19T17:30:00.000Z"); payload.notifyBefore = nil
        try await queue.enqueue(SyncQueueItem(id: "q1", taskId: "a", operation: .update,
            timestamp: Int(payload.updatedAt.timeIntervalSince1970 * 1000), payload: payload))
        _ = try await engine.push(token: "TOK", owner: "u1")
        #expect(await server.patches.first?.notifyBefore == 20)
    }
}
