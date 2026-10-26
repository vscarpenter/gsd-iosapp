import Foundation
import Testing
import GSDModel
import GSDStore
@testable import GSDSync
@testable import GSDWire

/// PATCH deliberately merges fields, like PocketBase: omitting saved_at cannot clear it.
private actor SavedServer: RequestExecuting {
    private var record: [String: Any]

    init(saved: Bool) {
        let stamp = "2026-10-26T12:00:00.000Z"
        record = ["id": "record000000001", "task_id": "article", "owner": "u1",
                  "title": "Read later", "description": "Web annotation", "urgent": false,
                  "important": true, "saved_at": saved ? stamp : "",
                  "client_created_at": stamp, "client_updated_at": stamp,
                  "updated": stamp, "device_id": "web"]
    }

    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if request.httpMethod == "PATCH", let body = request.httpBody {
            let fields = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            record.merge(fields) { _, new in new }
            record["updated"] = record["client_updated_at"]
        }
        let response: [String: Any] = request.httpMethod == "GET"
            ? ["page": 1, "perPage": 200, "totalItems": 1, "totalPages": 1, "items": [record]]
            : record
        return (try JSONSerialization.data(withJSONObject: response),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    func snapshot() throws -> Data { try JSONSerialization.data(withJSONObject: record) }

    func webReturnEvent() throws -> String {
        record["saved_at"] = ""
        record["description"] = "Web changed the annotation"
        record["client_updated_at"] = "2026-10-26T12:10:00.000Z"
        record["updated"] = record["client_updated_at"]
        record["device_id"] = "web"
        let data = try JSONSerialization.data(withJSONObject: ["action": "update", "record": record])
        return String(decoding: data, as: UTF8.self)
    }
}

@MainActor
struct SavedSyncLifecycleTests {
    nonisolated private static let token = "eyJhbGciOiJIUzI1NiJ9.eyJpZCI6InUxIiwiZXhwIjo5OTk5OTk5OTk5fQ.x"

    private func makeStack(_ server: SavedServer) throws -> (TaskStore, GRDBTaskRepository, GRDBSyncQueueRepository, SyncEngine) {
        let db = try AppDatabase.inMemory()
        let repo = GRDBTaskRepository(db)
        let queue = GRDBSyncQueueRepository(db)
        let defaults = UserDefaults(suiteName: "saved-sync-\(UUID().uuidString)")!
        let stamp = WireDate.parse("2026-10-26T12:05:00.000Z")!
        let store = TaskStore(repository: repo, smartViewRepository: GRDBSmartViewRepository(db),
                              archiveRepository: GRDBArchiveRepository(db), trashRepository: GRDBTrashRepository(db),
                              defaults: defaults, clock: { stamp }, syncQueue: queue)
        let engine = SyncEngine(client: PocketBaseClient(baseURL: "https://saved.test", executor: server),
                                tasks: repo, queue: queue, cursor: SyncCursor(defaults: defaults), deviceId: "ios",
                                tokenProvider: { Self.token }, now: { stamp.addingTimeInterval(1800) }, throttleMs: 0)
        return (store, repo, queue, engine)
    }

    @Test func webSavedPullNativeNoteAndReturnPushPreserveOneIdentity() async throws {
        let server = SavedServer(saved: true)
        let (store, repo, queue, engine) = try makeStack(server)
        let pulled = try await engine.pull(token: Self.token, since: "1970-01-01T00:00:00.000Z")
        #expect(pulled.applied == 1)
        #expect(try await repo.fetch(id: "article")?.isSaved == true)
        try await store.updateSavedNotes(id: "article", notes: "Native annotation")
        let notePush = try await engine.push(token: Self.token, owner: "u1")
        #expect(notePush.pushed == 1 && notePush.failed == 0)
        let noted = try JSONDecoder().decode(PocketBaseTaskRecord.self, from: await server.snapshot())
        #expect(noted.description == "Native annotation" && !noted.savedAt.isEmpty)
        try await store.returnToMatrix(id: "article", quadrant: .urgentNotImportant, dueDate: nil)
        let returnPush = try await engine.push(token: Self.token, owner: "u1")
        #expect(returnPush.pushed == 1 && returnPush.failed == 0)
        let returned = try JSONDecoder().decode(PocketBaseTaskRecord.self, from: await server.snapshot())
        #expect(returned.savedAt == "")
        #expect(returned.taskId == "article" && returned.urgent && !returned.important)
        #expect(returned.description == "Native annotation")
        #expect(try await repo.fetchAll().count == 1)
        #expect(try await queue.all().isEmpty)
    }

    @Test func nativeSavePushThenWebReturnRealtimeUpdatesNativePlacementAndNotes() async throws {
        let server = SavedServer(saved: false)
        let (store, repo, _, engine) = try makeStack(server)
        _ = try await engine.pull(token: Self.token, since: "1970-01-01T00:00:00.000Z")
        let task = try #require(try await repo.fetch(id: "article"))
        let saved = try await store.moveToSaved(task)
        let pushed = try await engine.push(token: Self.token, owner: "u1")
        #expect(pushed.pushed == 1 && pushed.failed == 0)
        let remote = try JSONDecoder().decode(PocketBaseTaskRecord.self, from: await server.snapshot())
        #expect(WireDate.parse(remote.savedAt) == saved.savedAt)
        await engine.applyRealtime(rawData: try await server.webReturnEvent())
        let returned = try #require(try await repo.fetch(id: "article"))
        #expect(!returned.isSaved)
        #expect(returned.description == "Web changed the annotation")
        #expect(try await repo.fetchAll().count == 1)
    }
}
