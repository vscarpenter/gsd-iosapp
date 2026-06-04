import Testing
import Foundation
@testable import GSDSync
import GSDStore
import GSDModel

struct SyncEngineRealtimeTests {
    final class EmptyExecutor: RequestExecuting, @unchecked Sendable {
        func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            (Data(#"{"page":1,"perPage":200,"totalItems":0,"totalPages":1,"items":[]}"#.utf8),
             HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }
    // token with id "u1"
    let token = "eyJhbGciOiJIUzI1NiJ9.eyJpZCI6InUxIiwiZXhwIjo5OTk5OTk5OTk5fQ.x"
    enum TokenError: Error { case unavailable }

    private func make(
        _ db: AppDatabase,
        deviceId: String = "dev-A",
        tokenProvider: (@Sendable () async throws -> String?)? = nil
    ) -> (SyncEngine, GRDBTaskRepository, GRDBSyncQueueRepository) {
        let tasks = GRDBTaskRepository(db); let queue = GRDBSyncQueueRepository(db)
        let eng = SyncEngine(client: PocketBaseClient(baseURL: "https://api.vinny.io", executor: EmptyExecutor()),
                             tasks: tasks, queue: queue,
                             cursor: SyncCursor(defaults: UserDefaults(suiteName: "t.\(UUID().uuidString)")!),
                             deviceId: deviceId, tokenProvider: tokenProvider ?? { self.token },
                             now: { Date(timeIntervalSince1970: 2_000_000_000) }, throttleMs: 0,
                             history: GRDBSyncHistoryRepository(db))
        return (eng, tasks, queue)
    }

    @Test func appliesForeignCreate() async throws {
        let db = try AppDatabase.inMemory(); let (eng, tasks, _) = make(db)
        let json = #"{"action":"create","record":{"task_id":"t1","owner":"u1","title":"From web","urgent":true,"important":false,"quadrant":"urgent-important","client_updated_at":"2033-05-18T03:33:20.000Z","device_id":"dev-B"}}"#
        await eng.applyRealtime(rawData: json)
        let local = try await tasks.fetch(id: "t1")
        #expect(local?.title == "From web")
    }

    @Test func echoFiltersOwnDevice() async throws {
        let db = try AppDatabase.inMemory(); let (eng, tasks, _) = make(db, deviceId: "dev-A")
        let json = #"{"action":"create","record":{"task_id":"t1","owner":"u1","title":"echo","client_updated_at":"2033-05-18T03:33:20.000Z","device_id":"dev-A"}}"#
        await eng.applyRealtime(rawData: json)
        #expect(try await tasks.fetch(id: "t1") == nil)     // own device → skipped
    }

    @Test func emptyDeviceIdIsApplied() async throws {
        let db = try AppDatabase.inMemory(); let (eng, tasks, _) = make(db, deviceId: "dev-A")
        let json = #"{"action":"create","record":{"task_id":"t1","owner":"u1","title":"web no-dev","client_updated_at":"2033-05-18T03:33:20.000Z","device_id":""}}"#
        await eng.applyRealtime(rawData: json)
        #expect(try await tasks.fetch(id: "t1") != nil)      // empty device_id → foreign → applied
    }

    @Test func ownerMismatchSkipped() async throws {
        let db = try AppDatabase.inMemory(); let (eng, tasks, _) = make(db)
        let json = #"{"action":"create","record":{"task_id":"t1","owner":"someone-else","title":"x","client_updated_at":"2033-05-18T03:33:20.000Z","device_id":"dev-B"}}"#
        await eng.applyRealtime(rawData: json)
        #expect(try await tasks.fetch(id: "t1") == nil)
    }

    @Test func ownerEventSkippedWhenTokenUnavailable() async throws {
        let db = try AppDatabase.inMemory()
        let (eng, tasks, _) = make(db, tokenProvider: { nil })
        let json = #"{"action":"create","record":{"task_id":"t1","owner":"u1","title":"x","client_updated_at":"2033-05-18T03:33:20.000Z","device_id":"dev-B"}}"#
        await eng.applyRealtime(rawData: json)
        #expect(try await tasks.fetch(id: "t1") == nil)
    }

    @Test func ownerEventSkippedWhenTokenProviderThrows() async throws {
        let db = try AppDatabase.inMemory()
        let (eng, tasks, _) = make(db, tokenProvider: { throw TokenError.unavailable })
        let json = #"{"action":"create","record":{"task_id":"t1","owner":"u1","title":"x","client_updated_at":"2033-05-18T03:33:20.000Z","device_id":"dev-B"}}"#
        await eng.applyRealtime(rawData: json)
        #expect(try await tasks.fetch(id: "t1") == nil)
    }

    @Test func ownerEventSkippedWhenTokenHasNoOwner() async throws {
        let db = try AppDatabase.inMemory()
        let (eng, tasks, _) = make(db, tokenProvider: { "not-a-jwt" })
        let json = #"{"action":"create","record":{"task_id":"t1","owner":"u1","title":"x","client_updated_at":"2033-05-18T03:33:20.000Z","device_id":"dev-B"}}"#
        await eng.applyRealtime(rawData: json)
        #expect(try await tasks.fetch(id: "t1") == nil)
    }

    @Test func ownerlessEventStillAppliesWhenTokenUnavailable() async throws {
        let db = try AppDatabase.inMemory()
        let (eng, tasks, _) = make(db, tokenProvider: { nil })
        let json = #"{"action":"create","record":{"task_id":"t1","owner":"","title":"legacy","client_updated_at":"2033-05-18T03:33:20.000Z","device_id":"dev-B"}}"#
        await eng.applyRealtime(rawData: json)
        #expect(try await tasks.fetch(id: "t1")?.title == "legacy")
    }

    @Test func lwwSkipsOlderRemote() async throws {
        let db = try AppDatabase.inMemory(); let (eng, tasks, _) = make(db)
        let fresh = Task(id: "t1", title: "local fresh", urgent: false, important: false,
                         createdAt: Date(timeIntervalSince1970: 9_000_000_000), updatedAt: Date(timeIntervalSince1970: 9_000_000_000))
        try await tasks.upsert(fresh)
        let json = #"{"action":"update","record":{"task_id":"t1","owner":"u1","title":"old remote","client_updated_at":"2001-01-01T00:00:00.000Z","device_id":"dev-B"}}"#
        await eng.applyRealtime(rawData: json)
        #expect(try await tasks.fetch(id: "t1")?.title == "local fresh")   // local newer → kept
    }

    @Test func deleteRemovesTask() async throws {
        let db = try AppDatabase.inMemory(); let (eng, tasks, _) = make(db)
        try await tasks.upsert(Task(id: "t1", title: "doomed", urgent: false, important: false,
                                    createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1)))
        let json = #"{"action":"delete","record":{"task_id":"t1","owner":"u1","device_id":"dev-B"}}"#
        await eng.applyRealtime(rawData: json)
        #expect(try await tasks.fetch(id: "t1") == nil)
    }

    @Test func deleteSkippedWhenTaskHasPendingQueueItem() async throws {
        let db = try AppDatabase.inMemory(); let (eng, tasks, queue) = make(db)
        try await tasks.upsert(Task(id: "t1", title: "just created locally", urgent: false, important: false,
                                    createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1)))
        try await queue.enqueue(SyncQueueItem(id: "q1", taskId: "t1", operation: .create, timestamp: 1))
        let json = #"{"action":"delete","record":{"task_id":"t1","owner":"u1","device_id":"dev-B"}}"#
        await eng.applyRealtime(rawData: json)
        #expect(try await tasks.fetch(id: "t1") != nil)   // queued → not dropped by realtime
    }

    @Test func malformedDoesNotCrash() async throws {
        let db = try AppDatabase.inMemory(); let (eng, _, _) = make(db)
        await eng.applyRealtime(rawData: "not json")
        await eng.applyRealtime(rawData: #"{"action":"create"}"#)   // no record
        #expect(Bool(true))   // reached here without throwing
    }
}
