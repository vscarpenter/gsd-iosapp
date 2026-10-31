import Testing
import Foundation
import GSDModel
@testable import GSDStore

/// Parity S9 (backlog B-04): the archive and the trash act as sync tombstones. Sync asks when a
/// task was archived or trashed, and moves it back to the live table in one write when a newer
/// remote edit outranks that.
struct TombstoneRepositoryTests {
    private func task(_ id: String, title: String = "t") -> Task {
        Task(id: id, title: title, urgent: false, important: false,
             createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1))
    }
    private let buriedAt = Date(timeIntervalSince1970: 5_000)

    @Test func aLiveTaskHasNoTombstone() async throws {
        let db = try AppDatabase.inMemory()
        try await GRDBTaskRepository(db).upsert(task("a"))
        #expect(try await GRDBTombstoneRepository(db).tombstoneDate(id: "a") == nil)
    }

    @Test func anArchivedTaskReportsWhenItWasArchived() async throws {
        let db = try AppDatabase.inMemory()
        try await GRDBArchiveRepository(db).archive(task("a"), at: buriedAt)
        #expect(try await GRDBTombstoneRepository(db).tombstoneDate(id: "a") == buriedAt)
    }

    @Test func aTrashedTaskReportsWhenItWasDeleted() async throws {
        let db = try AppDatabase.inMemory()
        try await GRDBTrashRepository(db).trash(task("a"), at: buriedAt)
        #expect(try await GRDBTombstoneRepository(db).tombstoneDate(id: "a") == buriedAt)
    }

    @Test func resurrectMovesAnArchivedTaskBackToTheLiveTable() async throws {
        let db = try AppDatabase.inMemory()
        try await GRDBArchiveRepository(db).archive(task("a"), at: buriedAt)
        try await GRDBTombstoneRepository(db).resurrect(task("a", title: "edited elsewhere"))
        let live = try await GRDBTaskRepository(db).fetch(id: "a")
        #expect(live?.title == "edited elsewhere")
        #expect(try await GRDBArchiveRepository(db).fetchAll().isEmpty)
    }

    @Test func resurrectMovesATrashedTaskBackToTheLiveTable() async throws {
        let db = try AppDatabase.inMemory()
        try await GRDBTrashRepository(db).trash(task("a"), at: buriedAt)
        try await GRDBTombstoneRepository(db).resurrect(task("a", title: "edited elsewhere"))
        let live = try await GRDBTaskRepository(db).fetch(id: "a")
        #expect(live?.title == "edited elsewhere")
        #expect(try await GRDBTrashRepository(db).fetchAll().isEmpty)
    }

    // MARK: Abandon (B-07)

    private func failedRow(_ id: String, taskId: String) -> SyncQueueItem {
        SyncQueueItem(id: id, taskId: taskId, operation: .create, timestamp: 1, retryCount: 5,
                      payload: task(taskId), status: .failed, lastAttemptAt: 1, failedAt: 1)
    }

    @Test func abandonMovesTheCurrentRowToTrashAndDropsOnlyItsQueueRows() async throws {
        let db = try AppDatabase.inMemory(); let queue = GRDBSyncQueueRepository(db)
        try await GRDBTaskRepository(db).upsert(task("a", title: "current"))
        try await queue.enqueue(failedRow("q1", taskId: "a"))
        try await queue.enqueue(failedRow("q2", taskId: "a"))
        try await queue.enqueue(failedRow("q3", taskId: "other"))
        let moved = try await GRDBTombstoneRepository(db).abandonToTrash(id: "a", at: buriedAt)
        let trashed = try await GRDBTrashRepository(db).fetchAllStamped()
        #expect(moved)
        #expect(try await GRDBTaskRepository(db).fetch(id: "a") == nil)
        #expect(trashed.map(\.task.title) == ["current"])
        #expect(trashed.first?.stampedAt == buriedAt)
        #expect(try await queue.all().map(\.id) == ["q3"])
    }

    // An edit that lands after the engine read the queue enqueues a pending row. It must survive.
    @Test func abandonRefusesATaskThatHasAPendingRow() async throws {
        let db = try AppDatabase.inMemory(); let queue = GRDBSyncQueueRepository(db)
        try await GRDBTaskRepository(db).upsert(task("a"))
        try await queue.enqueue(failedRow("q1", taskId: "a"))
        try await queue.enqueue(SyncQueueItem(id: "q2", taskId: "a", operation: .update, timestamp: 2, payload: task("a")))
        let moved = try await GRDBTombstoneRepository(db).abandonToTrash(id: "a", at: buriedAt)
        #expect(!moved)
        #expect(try await GRDBTaskRepository(db).fetch(id: "a") != nil)
        #expect(try await GRDBTrashRepository(db).fetchAll().isEmpty)
        #expect(try await queue.all().count == 2)
    }

    @Test func abandonOfATaskWithNoLiveRowChangesNothing() async throws {
        let db = try AppDatabase.inMemory(); let queue = GRDBSyncQueueRepository(db)
        try await queue.enqueue(failedRow("q1", taskId: "gone"))
        let moved = try await GRDBTombstoneRepository(db).abandonToTrash(id: "gone", at: buriedAt)
        #expect(!moved)
        #expect(try await queue.all().count == 1)
    }
}
