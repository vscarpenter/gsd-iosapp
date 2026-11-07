import Testing
import Foundation
import GSDModel
import GSDStore
@testable import GSDSync
@testable import GSDWire

/// D-10 (spec-notify-before): `notify_before` is always a number on the wire.
struct NotifyBeforeWireTests {
    private let stamp = Date(timeIntervalSince1970: 1_780_000_000)
    private func task(offset: Int?) -> Task {
        Task(id: "a", title: "t", urgent: false, important: false, createdAt: stamp, updatedAt: stamp,
             notifyBefore: offset)
    }

    @Test func theWireNeverCarriesANullOffset() throws {
        let record = TaskWireMapper.toWire(task(offset: nil), owner: "u", deviceId: "d", defaultReminder: 20)
        #expect(record.notifyBefore == 20)
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        #expect(json["notify_before"] as? Int == 20)   // present, never omitted
    }

    @Test func aZeroOffsetStaysZeroAndFiresAtTheDueTime() {
        #expect(TaskWireMapper.toWire(task(offset: 0), owner: "u", deviceId: "d", defaultReminder: 20).notifyBefore == 0)
    }

    @Test func changingTheDefaultDoesntMoveAnExistingNumber() {
        #expect(TaskWireMapper.toWire(task(offset: 30), owner: "u", deviceId: "d", defaultReminder: 5).notifyBefore == 30)
    }

    @Test func turningAReminderOffKeepsTheOffsetOnTheWire() {
        var off = task(offset: 60); off.notificationEnabled = false
        let record = TaskWireMapper.toWire(off, owner: "u", deviceId: "d", defaultReminder: 15)
        #expect(record.notificationEnabled == false)
        #expect(record.notifyBefore == 60)
    }

    // MARK: The drain (rule 2)

    final class BodyExecutor: RequestExecuting, @unchecked Sendable {
        private(set) var bodies: [Data] = []
        func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let method = request.httpMethod ?? "GET"
            if method == "GET" {
                let empty = #"{"page":1,"perPage":200,"totalItems":0,"totalPages":1,"items":[]}"#
                return (Data(empty.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            if let body = request.httpBody { bodies.append(body) }
            let reply = #"{"id":"rec_x","task_id":"a","title":"t","urgent":false,"important":false}"#
            return (Data(reply.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        func sentOffset() throws -> Int? {
            let json = try JSONSerialization.jsonObject(with: #require(bodies.last)) as? [String: Any]
            return json?["notify_before"] as? Int
        }
    }

    private func drain(payloadOffset: Int?, rowOffset: Int?, rowExists: Bool = true, defaultReminder: Int = 20)
        async throws -> (sent: Int?, row: Task?, queued: Int) {
        let db = try AppDatabase.inMemory()
        let tasks = GRDBTaskRepository(db), queue = GRDBSyncQueueRepository(db)
        let exec = BodyExecutor()
        if rowExists { try await tasks.upsert(task(offset: rowOffset)) }
        try await queue.enqueue(SyncQueueItem(id: "q1", taskId: "a", operation: .update, timestamp: 1,
                                              payload: task(offset: payloadOffset)))
        let engine = SyncEngine(client: PocketBaseClient(baseURL: "https://api.vinny.io", executor: exec),
                                tasks: tasks, queue: queue,
                                cursor: SyncCursor(defaults: UserDefaults(suiteName: "t.\(UUID().uuidString)")!),
                                deviceId: "dev-A", tokenProvider: { "TOK" }, throttleMs: 0,
                                defaultReminder: { defaultReminder })
        _ = try await engine.push(token: "TOK", owner: "u")
        return (try exec.sentOffset(), try await tasks.fetch(id: "a"), try await queue.pending().count)
    }

    @Test func aQueuedNullPayloadPushesANumberAndStoresItOnTheRowWithoutBumpingTheStamp() async throws {
        let r = try await drain(payloadOffset: nil, rowOffset: nil)
        #expect(r.sent == 20)
        #expect(r.row?.notifyBefore == 20)
        #expect(r.row?.updatedAt == stamp)   // no stamp bump
        #expect(r.queued == 0)               // nothing queued by the write-back
    }

    @Test func aQueuedNullPayloadTakesTheCurrentRowsNumber() async throws {
        let r = try await drain(payloadOffset: nil, rowOffset: 45)
        #expect(r.sent == 45)
        #expect(r.row?.notifyBefore == 45)
    }

    @Test func aQueuedNullPayloadForAGoneRowPushesTheDefault() async throws {
        let r = try await drain(payloadOffset: nil, rowOffset: nil, rowExists: false)
        #expect(r.sent == 20)
        #expect(r.row == nil)
    }

    @Test func aQueuedNumberIsPushedAsIs() async throws {
        let r = try await drain(payloadOffset: 0, rowOffset: 30)
        #expect(r.sent == 0)
    }
}

/// D2: the drain's write-back must set only `notifyBefore`, and only where it is still null. A
/// whole-row save reverts a local write that lands between the read and the write, and a second
/// complete in that window spawns a duplicate recurring instance.
struct NotifyBeforeDrainRaceTests {
    /// Reads the row, then lets a local write land before the engine's write-back, as an edit made
    /// on the main actor while the drain awaited the network would.
    final class RacyTasks: TaskRepository, @unchecked Sendable {
        let base: GRDBTaskRepository
        private var raced = false
        init(_ base: GRDBTaskRepository) { self.base = base }
        func upsert(_ task: Task) async throws { try await base.upsert(task) }
        func fetchAll() async throws -> [Task] { try await base.fetchAll() }
        func fetch(id: String) async throws -> Task? {
            let row = try await base.fetch(id: id)
            if !raced, var local = row {
                raced = true
                local.completed = true
                local.updatedAt = local.updatedAt.addingTimeInterval(60)
                try await base.upsert(local)   // the local toggle, landing after the engine's read
            }
            return row
        }
        func setNotifyBeforeIfNull(id: String, value: Int) async throws {
            try await base.setNotifyBeforeIfNull(id: id, value: value)
        }
        func delete(id: String) async throws { try await base.delete(id: id) }
        func replaceAll(_ tasks: [Task]) async throws { try await base.replaceAll(tasks) }
        func observeAll() -> AsyncThrowingStream<[Task], Error> { base.observeAll() }
    }

    @Test func aLocalToggleInTheWindowSurvivesTheWriteBack() async throws {
        let db = try AppDatabase.inMemory()
        let base = GRDBTaskRepository(db), queue = GRDBSyncQueueRepository(db)
        let stamp = Date(timeIntervalSince1970: 1_780_000_000)
        let legacy = Task(id: "a", title: "t", urgent: false, important: false, createdAt: stamp, updatedAt: stamp)
        try await base.upsert(legacy)
        try await queue.enqueue(SyncQueueItem(id: "q1", taskId: "a", operation: .update, timestamp: 1, payload: legacy))
        let engine = SyncEngine(client: PocketBaseClient(baseURL: "https://api.vinny.io",
                                                         executor: NotifyBeforeWireTests.BodyExecutor()),
                                tasks: RacyTasks(base), queue: queue,
                                cursor: SyncCursor(defaults: UserDefaults(suiteName: "t.\(UUID().uuidString)")!),
                                deviceId: "dev-A", tokenProvider: { "TOK" }, throttleMs: 0,
                                defaultReminder: { 20 })
        _ = try await engine.push(token: "TOK", owner: "u")
        let row = try #require(try await base.fetch(id: "a"))
        #expect(row.completed)                    // the toggle was not reverted
        #expect(row.updatedAt == stamp.addingTimeInterval(60))
        #expect(row.notifyBefore == 20)           // and the number still settled
    }

    @Test func theWriteBackLeavesANumberAlone() async throws {
        let db = try AppDatabase.inMemory()
        let repo = GRDBTaskRepository(db)
        let stamp = Date(timeIntervalSince1970: 1_780_000_000)
        try await repo.upsert(Task(id: "a", title: "t", urgent: false, important: false,
                                   createdAt: stamp, updatedAt: stamp, notifyBefore: 45))
        try await repo.setNotifyBeforeIfNull(id: "a", value: 20)
        #expect(try await repo.fetch(id: "a")?.notifyBefore == 45)
        try await repo.setNotifyBeforeIfNull(id: "gone", value: 20)   // a missing row is a no-op
    }
}
