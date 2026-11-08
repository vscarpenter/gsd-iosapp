import Testing
import Foundation
import GSDModel
import GSDStore
@testable import GSDSync
@testable import GSDWire

/// Parity S9 (backlog B-04). Archived and trashed tasks used to come back: pull and realtime looked
/// only at the live table, so a cursor reset or an edit on another device made them active again.
/// A tombstone now holds unless the remote edit is strictly newer than the archive or delete.
struct SyncEngineTombstoneTests {
    final class ListExecutor: RequestExecuting, @unchecked Sendable {
        var json = #"{"page":1,"perPage":200,"totalItems":0,"totalPages":1,"items":[]}"#
        func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    // token with id "u1"
    private static let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJpZCI6InUxIiwiZXhwIjo5OTk5OTk5OTk5fQ.x"
    private static let buriedAt = WireDate.parse("2026-06-15T09:00:00.000Z")!
    private static let before = "2026-06-14T09:00:00.000Z"
    private static let after = "2026-06-16T09:00:00.000Z"

    private func engine(_ db: AppDatabase, _ exec: ListExecutor = ListExecutor()) -> SyncEngine {
        SyncEngine(client: PocketBaseClient(baseURL: "https://api.vinny.io", executor: exec),
                   tasks: GRDBTaskRepository(db), queue: GRDBSyncQueueRepository(db),
                   tombstones: GRDBTombstoneRepository(db),
                   cursor: SyncCursor(defaults: UserDefaults(suiteName: "t.\(UUID().uuidString)")!),
                   deviceId: "dev-A", tokenProvider: { Self.jwt }, rawToken: { Self.jwt },
                   now: { Date(timeIntervalSince1970: 2_000_000_000) }, throttleMs: 0)
    }
    private func task(_ id: String) -> Task {
        Task(id: id, title: "local", urgent: false, important: false,
             createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1))
    }
    private func remote(_ id: String, updated: String) -> String {
        #"{"id":"rec_\#(id)","task_id":"\#(id)","owner":"u1","title":"remote","urgent":false,"important":false,"client_updated_at":"\#(updated)","device_id":"dev-B","updated":"\#(updated)"}"#
    }
    private func pullListing(_ items: String...) -> ListExecutor {
        let exec = ListExecutor()
        exec.json = #"{"page":1,"perPage":200,"totalItems":\#(items.count),"totalPages":1,"items":[\#(items.joined(separator: ","))]}"#
        return exec
    }
    private func realtime(_ id: String, updated: String) -> String {
        #"{"action":"update","record":\#(remote(id, updated: updated))}"#
    }

    // MARK: Pull

    @Test func pullLeavesAnArchivedTaskArchivedWhenTheRemoteCopyIsOlder() async throws {
        let db = try AppDatabase.inMemory()
        try await GRDBArchiveRepository(db).archive(task("a"), at: Self.buriedAt)
        let (applied, _, _) = try await engine(db, pullListing(remote("a", updated: Self.before)))
            .pull(token: Self.jwt, since: "1970-01-01 00:00:00.000Z")
        #expect(applied == 0)
        #expect(try await GRDBTaskRepository(db).fetch(id: "a") == nil)
        #expect(try await GRDBArchiveRepository(db).fetchAll().map(\.id) == ["a"])
    }

    @Test func pullLeavesATrashedTaskTrashedWhenTheRemoteCopyIsOlder() async throws {
        let db = try AppDatabase.inMemory()
        try await GRDBTrashRepository(db).trash(task("a"), at: Self.buriedAt)
        _ = try await engine(db, pullListing(remote("a", updated: Self.before)))
            .pull(token: Self.jwt, since: "1970-01-01 00:00:00.000Z")
        #expect(try await GRDBTaskRepository(db).fetch(id: "a") == nil)
        #expect(try await GRDBTrashRepository(db).fetchAll().map(\.id) == ["a"])
    }

    @Test func pullBringsBackAnArchivedTaskEditedElsewhereAfterwards() async throws {
        let db = try AppDatabase.inMemory()
        try await GRDBArchiveRepository(db).archive(task("a"), at: Self.buriedAt)
        let (applied, _, _) = try await engine(db, pullListing(remote("a", updated: Self.after)))
            .pull(token: Self.jwt, since: "1970-01-01 00:00:00.000Z")
        #expect(applied == 1)
        #expect(try await GRDBTaskRepository(db).fetch(id: "a")?.title == "remote")
        #expect(try await GRDBArchiveRepository(db).fetchAll().isEmpty)   // never in two tables
    }

    @Test func pullKeepsATrashedTaskWhoseQueuedDeleteWillStillLand() async throws {
        // Push will still send this delete: the remote edit predates it. Bringing the row back would
        // let that delete, then reconcile, remove the task and its Trash copy for good.
        let db = try AppDatabase.inMemory()
        try await GRDBTrashRepository(db).trash(task("a"), at: Self.buriedAt)
        let queuedAfterTheEdit = Int(WireDate.parse(Self.after)!.timeIntervalSince1970 * 1000) + 1
        try await GRDBSyncQueueRepository(db).enqueue(SyncQueueItem(id: "d1", taskId: "a", operation: .delete, timestamp: queuedAfterTheEdit))
        _ = try await engine(db, pullListing(remote("a", updated: Self.after)))
            .pull(token: Self.jwt, since: "1970-01-01 00:00:00.000Z")
        #expect(try await GRDBTaskRepository(db).fetch(id: "a") == nil)
        #expect(try await GRDBTrashRepository(db).fetchAll().map(\.id) == ["a"])
    }

    @Test func pullBringsBackATrashedTaskWhoseQueuedDeleteIsStale() async throws {
        // Push will drop this delete: the remote edit is newer. Suppressing the record would strand
        // the task in Trash here once the cursor moves past it.
        let db = try AppDatabase.inMemory()
        try await GRDBTrashRepository(db).trash(task("a"), at: Self.buriedAt)
        let queuedBeforeTheEdit = Int(Self.buriedAt.timeIntervalSince1970 * 1000)
        try await GRDBSyncQueueRepository(db).enqueue(SyncQueueItem(id: "d1", taskId: "a", operation: .delete, timestamp: queuedBeforeTheEdit))
        _ = try await engine(db, pullListing(remote("a", updated: Self.after)))
            .pull(token: Self.jwt, since: "1970-01-01 00:00:00.000Z")
        #expect(try await GRDBTaskRepository(db).fetch(id: "a")?.title == "remote")
        #expect(try await GRDBTrashRepository(db).fetchAll().isEmpty)
    }

    // MARK: Realtime

    @Test func realtimeLeavesAnArchivedTaskArchivedWhenTheRemoteCopyIsOlder() async throws {
        let db = try AppDatabase.inMemory()
        try await GRDBArchiveRepository(db).archive(task("a"), at: Self.buriedAt)
        await engine(db).applyRealtime(rawData: realtime("a", updated: Self.before))
        #expect(try await GRDBTaskRepository(db).fetch(id: "a") == nil)
        #expect(try await GRDBArchiveRepository(db).fetchAll().map(\.id) == ["a"])
    }

    @Test func realtimeBringsBackATrashedTaskEditedElsewhereAfterwards() async throws {
        // Trashed, and the delete already pushed: nothing is queued, so a newer edit wins.
        let db = try AppDatabase.inMemory()
        try await GRDBTrashRepository(db).trash(task("a"), at: Self.buriedAt)
        await engine(db).applyRealtime(rawData: realtime("a", updated: Self.after))
        #expect(try await GRDBTaskRepository(db).fetch(id: "a")?.title == "remote")
        #expect(try await GRDBTrashRepository(db).fetchAll().isEmpty)
    }
}

/// IOS-TOMBSTONE-MERGE (S-IOS-02, option A): a task that comes back over its archive or Trash row
/// merges the server copy into that row, as every other way a task comes back does, so this
/// device's own fields survive: rich time entries, `parentTaskId`, and reminder state.
extension SyncEngineTombstoneTests {
    private static let due = "2026-06-20T15:00:00.000Z"

    /// A buried task carrying this device's own fields. Its due date matches the server copy's, so
    /// B-55's moved-due reset doesn't apply.
    private func richTask(_ id: String) -> Task {
        let started = WireDate.parse("2026-06-10T09:00:00.000Z")!
        var task = task(id)
        task.dueDate = WireDate.parse(Self.due)
        task.parentTaskId = "parent-1"
        task.timeEntries = [TimeEntry(id: "e1", startedAt: started, endedAt: started.addingTimeInterval(1500),
                                      notes: "Left a voicemail")]
        task.notificationSent = true
        task.lastNotificationAt = WireDate.parse("2026-06-14T14:45:00.000Z")
        task.snoozedUntil = WireDate.parse("2026-06-20T14:30:00.000Z")
        return task
    }

    private func remoteWithDue(_ id: String, updated: String) -> String {
        #"{"id":"rec_\#(id)","task_id":"\#(id)","owner":"u1","title":"remote","urgent":false,"important":false,"due_date":"\#(Self.due)","client_updated_at":"\#(updated)","device_id":"dev-B","updated":"\#(updated)"}"#
    }

    private func expectDeviceFieldsKept(_ back: Task?, from buried: Task) {
        #expect(back?.title == "remote")                                   // the server copy wins the synced fields
        #expect(back?.timeEntries == buried.timeEntries)
        #expect(back?.parentTaskId == "parent-1")
        #expect(back?.notificationSent == true && back?.lastNotificationAt == buried.lastNotificationAt)
        #expect(back?.snoozedUntil == buried.snoozedUntil)
    }

    @Test func aTrashedTaskPulledBackKeepsThisDevicesFields() async throws {
        let db = try AppDatabase.inMemory()
        let buried = richTask("a")
        try await GRDBTrashRepository(db).trash(buried, at: Self.buriedAt)
        _ = try await engine(db, pullListing(remoteWithDue("a", updated: Self.after)))
            .pull(token: Self.jwt, since: "1970-01-01 00:00:00.000Z")
        expectDeviceFieldsKept(try await GRDBTaskRepository(db).fetch(id: "a"), from: buried)
    }

    @Test func anArchivedTaskPulledBackKeepsThisDevicesFields() async throws {
        let db = try AppDatabase.inMemory()
        let buried = richTask("a")
        try await GRDBArchiveRepository(db).archive(buried, at: Self.buriedAt)
        _ = try await engine(db, pullListing(remoteWithDue("a", updated: Self.after)))
            .pull(token: Self.jwt, since: "1970-01-01 00:00:00.000Z")
        expectDeviceFieldsKept(try await GRDBTaskRepository(db).fetch(id: "a"), from: buried)
    }

    /// B-55 still applies through the mapper: a server copy that moved the due date is a new reminder.
    @Test func aTrashedTaskPulledBackWithAMovedDueDateResetsItsReminderState() async throws {
        let db = try AppDatabase.inMemory()
        let buried = richTask("a")
        try await GRDBTrashRepository(db).trash(buried, at: Self.buriedAt)
        let moved = remoteWithDue("a", updated: Self.after).replacingOccurrences(of: Self.due, with: "2026-06-22T15:00:00.000Z")
        _ = try await engine(db, pullListing(moved)).pull(token: Self.jwt, since: "1970-01-01 00:00:00.000Z")
        let back = try await GRDBTaskRepository(db).fetch(id: "a")
        #expect(back?.timeEntries == buried.timeEntries && back?.parentTaskId == "parent-1")
        #expect(back?.notificationSent == false && back?.lastNotificationAt == nil && back?.snoozedUntil == nil)
    }

    @Test func aTrashedTaskBroughtBackByRealtimeKeepsThisDevicesFields() async throws {
        let db = try AppDatabase.inMemory()
        let buried = richTask("a")
        try await GRDBTrashRepository(db).trash(buried, at: Self.buriedAt)
        let event = #"{"action":"update","record":\#(remoteWithDue("a", updated: Self.after))}"#
        await engine(db).applyRealtime(rawData: event)
        expectDeviceFieldsKept(try await GRDBTaskRepository(db).fetch(id: "a"), from: buried)
    }
}
