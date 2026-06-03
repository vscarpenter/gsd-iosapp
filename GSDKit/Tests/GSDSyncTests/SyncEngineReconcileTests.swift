import Testing
import Foundation
import GSDModel
import GSDStore
@testable import GSDSync

struct SyncEngineReconcileTests {
    final class IndexExecutor: RequestExecuting, @unchecked Sendable {
        var indexJSON = #"{"page":1,"perPage":200,"totalItems":0,"totalPages":1,"items":[]}"#
        func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            (Data(indexJSON.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }
    private func task(_ id: String) -> Task {
        Task(id: id, title: id, urgent: false, important: false, createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
    }
    private func engine(tasks: GRDBTaskRepository, queue: GRDBSyncQueueRepository, exec: IndexExecutor) -> SyncEngine {
        SyncEngine(client: PocketBaseClient(baseURL: "https://api.vinny.io", executor: exec),
                   tasks: tasks, queue: queue, cursor: SyncCursor(defaults: UserDefaults(suiteName: "t.\(UUID().uuidString)")!),
                   deviceId: "d", tokenProvider: { "TOK" }, now: { Date(timeIntervalSince1970: 2_000_000_000) }, throttleMs: 0)
    }

    @Test func deletesOnlyOrphans() async throws {
        let db = try AppDatabase.inMemory(); let tasks = GRDBTaskRepository(db); let queue = GRDBSyncQueueRepository(db)
        for id in ["a", "b", "c", "d"] { try await tasks.upsert(task(id)) }
        let exec = IndexExecutor()   // remote has a, b
        exec.indexJSON = #"{"page":1,"perPage":200,"totalItems":2,"totalPages":1,"items":[{"task_id":"a","id":"r1"},{"task_id":"b","id":"r2"}]}"#
        try await queue.enqueue(SyncQueueItem(id: "q", taskId: "c", operation: .update, timestamp: 1, payload: task("c")))  // c is queued
        let deleted = try await engine(tasks: tasks, queue: queue, exec: exec).reconcileDeletions(token: "TOK")
        #expect(deleted == 1)                                   // only d (absent-remote AND not-queued)
        let survivingD = try await tasks.fetch(id: "d")
        let survivingA = try await tasks.fetch(id: "a")
        let survivingC = try await tasks.fetch(id: "c")          // hoisted: two `await`s in one #expect && trips the autoclosure
        #expect(survivingD == nil)
        #expect(survivingA != nil && survivingC != nil)
    }

    @Test func seedScenarioDeletesNothing() async throws {     // first-sync seed protects everything
        let db = try AppDatabase.inMemory(); let tasks = GRDBTaskRepository(db); let queue = GRDBSyncQueueRepository(db)
        for id in ["a", "b"] { try await tasks.upsert(task(id)); try await queue.enqueue(SyncQueueItem(id: "q-\(id)", taskId: id, operation: .update, timestamp: 1, payload: task(id))) }
        let deleted = try await engine(tasks: tasks, queue: queue, exec: IndexExecutor()).reconcileDeletions(token: "TOK")  // empty remote
        #expect(deleted == 0)                                   // all queued → none deleted
    }

    // Create-aware executor: a POST adds the record to what later GETs return, a DELETE removes it.
    // A static stub can't model "create remotely, then see it in the post-push reconcile index", so
    // the orchestration test below would otherwise pass for the wrong reason (push silently failing).
    final class StatefulExecutor: RequestExecuting, @unchecked Sendable {
        private var records: [String: String] = [:]   // task_id → recordId
        private var counter = 0
        private(set) var posts = 0
        func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let url = request.url!
            func resp(_ s: String, _ code: Int = 200) -> (Data, HTTPURLResponse) {
                (Data(s.utf8), HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!)
            }
            switch request.httpMethod ?? "GET" {
            case "POST":
                counter += 1; posts += 1
                let recordId = "rec_\(counter)"
                records[taskId(from: request.httpBody)] = recordId
                return resp(#"{"id":"\#(recordId)","task_id":"\#(taskId(from: request.httpBody))","title":"t","urgent":false,"important":false}"#)
            case "PATCH":
                return resp(#"{"id":"rec","task_id":"a","title":"t","urgent":false,"important":false}"#)
            case "DELETE":
                let recordId = url.lastPathComponent
                records = records.filter { $0.value != recordId }
                return resp("", 204)
            default:   // GET — current remote index/list
                let items = records.map {
                    #"{"task_id":"\#($0.key)","id":"\#($0.value)","title":"t","urgent":false,"important":false,"client_updated_at":"2026-06-15T09:00:00.000Z"}"#
                }.joined(separator: ",")
                return resp(#"{"page":1,"perPage":200,"totalItems":\#(records.count),"totalPages":1,"items":[\#(items)]}"#)
            }
        }
        private func taskId(from body: Data?) -> String {
            guard let body, let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let id = obj["task_id"] as? String else { return "unknown" }
            return id
        }
    }
    private func jwt(id: String) -> String {
        let payload = Data(#"{"id":"\#(id)","exp":9999999999}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "h.\(payload).s"
    }

    @Test func notSignedInWhenNoToken() async throws {
        let db = try AppDatabase.inMemory()
        let engine = SyncEngine(client: PocketBaseClient(baseURL: "https://api.vinny.io", executor: IndexExecutor()),
                                tasks: GRDBTaskRepository(db), queue: GRDBSyncQueueRepository(db),
                                cursor: SyncCursor(defaults: UserDefaults(suiteName: "t.\(UUID().uuidString)")!),
                                deviceId: "d", tokenProvider: { nil }, now: { Date(timeIntervalSince1970: 1) }, throttleMs: 0)
        let result = await engine.sync(trigger: .manual)
        #expect(result.notSignedIn == true)
    }

    @Test func syncSeedsPushesAndSurvivesReconcile() async throws {   // the data-wipe guard, end-to-end
        let db = try AppDatabase.inMemory(); let tasks = GRDBTaskRepository(db); let queue = GRDBSyncQueueRepository(db)
        try await tasks.upsert(task("offline-1"))   // created while signed-out (pre-sync)
        let exec = StatefulExecutor()
        let engine = SyncEngine(client: PocketBaseClient(baseURL: "https://api.vinny.io", executor: exec),
                                tasks: tasks, queue: queue, cursor: SyncCursor(defaults: UserDefaults(suiteName: "t.\(UUID().uuidString)")!),
                                deviceId: "d", tokenProvider: { self.jwt(id: "u1") },
                                now: { Date(timeIntervalSince1970: 2_000_000_000) }, throttleMs: 0)
        let result = await engine.sync(trigger: .launch)
        #expect(result.notSignedIn == false && result.error == nil)
        #expect(result.pushed == 1)                       // offline-1 seeded → created remotely
        let survivor = try await tasks.fetch(id: "offline-1")
        #expect(survivor != nil)                          // survives: in the post-push remote index → reconcile keeps it
        #expect(result.deleted == 0)
    }

    @Test func resetCursorClearsPersistedCursor() async throws {
        let defaults = UserDefaults(suiteName: "t.\(UUID().uuidString)")!
        let cursor = SyncCursor(defaults: defaults)
        cursor.advance(maxApplied: Date(timeIntervalSince1970: 1000), now: Date(timeIntervalSince1970: 1_000_000))
        #expect(cursor.load() != nil)
        let db = try AppDatabase.inMemory()
        let engine = SyncEngine(client: PocketBaseClient(baseURL: "https://api.vinny.io", executor: IndexExecutor()),
                                tasks: GRDBTaskRepository(db), queue: GRDBSyncQueueRepository(db),
                                cursor: cursor, deviceId: "d", tokenProvider: { nil }, now: { Date(timeIntervalSince1970: 1) }, throttleMs: 0)
        await engine.resetCursor()
        #expect(cursor.load() == nil)   // shared UserDefaults backing: clearing on the actor's copy is visible here
    }

    @Test func syncErrorsWhenTokenHasNoOwnerClaim() async throws {
        let db = try AppDatabase.inMemory(); let tasks = GRDBTaskRepository(db)
        try await tasks.upsert(task("local-1"))
        let exec = StatefulExecutor()
        let tokenNoId = "h.\(Data(#"{"exp":9999999999}"#.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")).s"
        let engine = SyncEngine(client: PocketBaseClient(baseURL: "https://api.vinny.io", executor: exec),
                                tasks: tasks, queue: GRDBSyncQueueRepository(db),
                                cursor: SyncCursor(defaults: UserDefaults(suiteName: "t.\(UUID().uuidString)")!),
                                deviceId: "d", tokenProvider: { tokenNoId }, now: { Date(timeIntervalSince1970: 2_000_000_000) }, throttleMs: 0)
        let result = await engine.sync(trigger: .manual)
        #expect(result.notSignedIn == false)
        #expect(result.error != nil)   // failed fast on a missing owner claim — did NOT push owner:""
    }
}
