import Testing
import Foundation
import GRDB
import GSDModel
@testable import GSDStore

/// Undo from Trash brings the task back, queues its create, and removes its waiting delete in one
/// write. A delete left in the queue would land after the create and take the task off the server.
@MainActor
struct TaskStoreUndoTests {
    private final class Clock: @unchecked Sendable { var date: Date; init(_ date: Date) { self.date = date } }
    private static let start = Date(timeIntervalSince1970: 1_800_000_000)

    private struct Rig {
        let store: TaskStore
        let queue: GRDBSyncQueueRepository
        let tasks: GRDBTaskRepository
        let trash: GRDBTrashRepository
        let db: AppDatabase
    }

    private func make(clock: Clock = Clock(start)) throws -> Rig {
        let db = try AppDatabase.inMemory()
        let queue = GRDBSyncQueueRepository(db)
        let tasks = GRDBTaskRepository(db)
        let trash = GRDBTrashRepository(db)
        let store = TaskStore(repository: tasks, smartViewRepository: GRDBSmartViewRepository(db),
                              archiveRepository: GRDBArchiveRepository(db), trashRepository: trash,
                              defaults: UserDefaults(suiteName: "undo.\(UUID().uuidString)")!,
                              clock: { clock.date }, syncQueue: queue)
        return Rig(store: store, queue: queue, tasks: tasks, trash: trash, db: db)
    }

    private func task(_ id: String) -> Task {
        Task(id: id, title: id, urgent: false, important: false,
             createdAt: Date(timeIntervalSince1970: 1_000), updatedAt: Date(timeIntervalSince1970: 1_000))
    }

    private func rows(_ rig: Rig, for id: String) async throws -> [SyncQueueItem] {
        try await rig.queue.all().filter { $0.taskId == id }
    }

    @Test("Undo from Trash removes the delete that is waiting out its backoff")
    func undoRemovesTheWaitingDelete() async throws {
        let rig = try make()
        try await rig.tasks.upsert(task("a"))
        try await rig.store.delete(task("a"))
        var waiting = try #require(try await rows(rig, for: "a").first)
        waiting.retryCount = 1
        waiting.lastAttemptAt = Int(Self.start.timeIntervalSince1970 * 1000)
        try await rig.queue.update(waiting)

        try await rig.store.restoreFromTrash(id: "a")

        let queued = try await rows(rig, for: "a").map(\.operation)
        let live = try await rig.tasks.fetch(id: "a")
        let trashed = try await rig.trash.fetchAll()
        #expect(queued == [.create])
        #expect(live != nil)
        #expect(trashed.isEmpty)
    }

    @Test("a failed Undo leaves the task in Trash with its delete still queued")
    func failedUndoKeepsTheTaskInTrashWithItsDelete() async throws {
        let rig = try make()
        try await rig.tasks.upsert(task("a"))
        try await rig.store.delete(task("a"))
        // Installed after the Trash, so only the Undo's queue write is refused.
        try await rig.db.writer.write { db in
            try db.execute(sql: "CREATE TRIGGER refuseQueue BEFORE INSERT ON syncQueue BEGIN SELECT RAISE(ABORT, 'refused'); END")
        }

        await #expect(throws: (any Error).self) { try await rig.store.restoreFromTrash(id: "a") }

        let trashed = try await rig.trash.fetchAll().map(\.id)
        let queued = try await rows(rig, for: "a").map(\.operation)
        let live = try await rig.tasks.fetch(id: "a")
        #expect(trashed == ["a"])
        #expect(queued == [.delete])
        #expect(live == nil)
    }

    @Test("Trash, Undo, then Trash again leaves only the second Trash's delete")
    func trashUndoTrashLeavesOneDelete() async throws {
        let clock = Clock(Self.start)
        let rig = try make(clock: clock)
        try await rig.tasks.upsert(task("a"))
        try await rig.store.delete(task("a"))
        clock.date = Self.start.addingTimeInterval(10)
        try await rig.store.restoreFromTrash(id: "a")
        let secondTrash = Self.start.addingTimeInterval(20)
        clock.date = secondTrash
        try await rig.store.delete(task("a"))

        let queued = try await rows(rig, for: "a")
        #expect(queued.map(\.operation) == [.delete])
        #expect(queued.first?.timestamp == Int(secondTrash.timeIntervalSince1970 * 1000))
    }
}
