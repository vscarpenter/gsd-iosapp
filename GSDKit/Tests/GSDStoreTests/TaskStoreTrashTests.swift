import Testing
import Foundation
import GSDModel
@testable import GSDStore

/// Soft delete. The behaviour that matters most here is what does NOT change: deleting a
/// task must still record a `.delete` for sync before it touches the local row, so the two
/// clients stay identical on the wire while both offer a way back.
@MainActor
struct TaskStoreTrashTests {
    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }()
    private func day(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 9) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d; c.hour = h
        return cal.date(from: c)!
    }
    private var now: Date { day(2026, 6, 15, 9) }

    private func makeStore(clock: Date? = nil,
                           queue: (any SyncQueueRepository)? = nil) throws -> (TaskStore, AppDatabase) {
        let db = try AppDatabase.inMemory()
        let suite = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        let fixed = clock ?? now
        let store = TaskStore(repository: GRDBTaskRepository(db, now: { fixed }),
                              smartViewRepository: GRDBSmartViewRepository(db),
                              archiveRepository: GRDBArchiveRepository(db, now: { fixed }),
                              trashRepository: GRDBTrashRepository(db, now: { fixed }),
                              defaults: suite,
                              clock: { fixed }, newID: { "id" }, calendar: cal,
                              syncQueue: queue ?? GRDBSyncQueueRepository(db))
        return (store, db)
    }

    private func task(_ id: String) -> Task {
        Task(id: id, title: id, urgent: false, important: false,
             createdAt: day(2026, 1, 1), updatedAt: day(2026, 1, 1))
    }

    private func waitForTasks(_ store: TaskStore, count: Int) async throws {
        store.start(); var w = 0
        while store.tasks.count != count && w < 100 {
            try await _Concurrency.Task.sleep(for: .milliseconds(10)); w += 1
        }
    }

    // MARK: delete moves to the trash

    @Test func deleteMovesTheTaskToTheTrashInsteadOfDroppingIt() async throws {
        let (store, _) = try makeStore()
        try await store.create(task("a"))
        try await waitForTasks(store, count: 1)

        try await store.delete(task("a"))
        try await waitForTasks(store, count: 0)

        let trashed = try await store.trashedTasks()
        #expect(trashed.map(\.task.id) == ["a"])
        #expect(trashed.first?.stampedAt == now)
        #expect(trashed.first?.stampKey == .deletedAt)
    }

    @Test func deleteStillEnqueuesADeleteForSync() async throws {
        // The wire contract is unchanged: trash is local recovery layered over the same
        // server delete the web client performs.
        let (store, db) = try makeStore()
        try await store.create(task("a"))
        try await waitForTasks(store, count: 1)

        try await store.delete(task("a"))

        let queued = try await GRDBSyncQueueRepository(db).pending()
        #expect(queued.contains { $0.taskId == "a" && $0.operation == .delete })
    }

    @Test func aTrashedTaskIsNotInTheActiveSnapshot() async throws {
        let (store, _) = try makeStore()
        try await store.create(task("a"))
        try await store.create(task("b"))
        try await waitForTasks(store, count: 2)

        try await store.delete(task("a"))
        try await waitForTasks(store, count: 1)
        #expect(store.tasks.map(\.id) == ["b"])
    }

    // MARK: restore

    @Test func restoreBringsTheTaskBackToTheActiveList() async throws {
        let (store, _) = try makeStore()
        try await store.create(task("a"))
        try await waitForTasks(store, count: 1)
        try await store.delete(task("a"))
        try await waitForTasks(store, count: 0)

        try await store.restoreFromTrash(id: "a")
        try await waitForTasks(store, count: 1)

        #expect(store.tasks.map(\.id) == ["a"])
        #expect(try await store.trashedTasks().isEmpty)
    }

    @Test func restoreEnqueuesACreateBecauseTheServerAlreadyDeletedIt() async throws {
        let (store, db) = try makeStore()
        try await store.create(task("a"))
        try await waitForTasks(store, count: 1)
        try await store.delete(task("a"))
        try await store.restoreFromTrash(id: "a")

        let queued = try await GRDBSyncQueueRepository(db).pending()
        #expect(queued.contains { $0.taskId == "a" && $0.operation == .create })
    }

    @Test func restoringAnUnknownIdIsANoOp() async throws {
        let (store, _) = try makeStore()
        try await store.restoreFromTrash(id: "nope")
        #expect(store.tasks.isEmpty)
    }

    // MARK: permanent removal

    @Test func deleteForeverRemovesTheRowForGood() async throws {
        let (store, _) = try makeStore()
        try await store.create(task("a"))
        try await waitForTasks(store, count: 1)
        try await store.delete(task("a"))

        try await store.deleteForever(id: "a")
        #expect(try await store.trashedTasks().isEmpty)
    }

    @Test func emptyTrashReturnsHowManyItPurged() async throws {
        let (store, _) = try makeStore()
        for id in ["a", "b", "c"] { try await store.create(task(id)) }
        try await waitForTasks(store, count: 3)
        for id in ["a", "b", "c"] { try await store.delete(task(id)) }

        #expect(try await store.emptyTrash() == 3)
        #expect(try await store.trashedTasks().isEmpty)
    }

    // MARK: retention sweep

    @Test func sweepPurgesRowsPastTheRetentionWindowAndKeepsTheRest() async throws {
        // Trash one task "now", then run the sweep from a clock 31 days later.
        let (store, db) = try makeStore()
        try await store.create(task("old"))
        try await waitForTasks(store, count: 1)
        try await store.delete(task("old"))

        let later = now.addingTimeInterval(31 * 86_400)
        let suite = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        let futureStore = TaskStore(repository: GRDBTaskRepository(db, now: { later }),
                                    smartViewRepository: GRDBSmartViewRepository(db),
                                    archiveRepository: GRDBArchiveRepository(db, now: { later }),
                                    trashRepository: GRDBTrashRepository(db, now: { later }),
                                    defaults: suite,
                                    clock: { later }, newID: { "id" }, calendar: cal,
                                    syncQueue: GRDBSyncQueueRepository(db))

        #expect(try await futureStore.runTrashRetentionSweep() == 1)
        #expect(try await futureStore.trashedTasks().isEmpty)
    }

    @Test func sweepKeepsARowInsideTheWindow() async throws {
        let (store, _) = try makeStore()
        try await store.create(task("recent"))
        try await waitForTasks(store, count: 1)
        try await store.delete(task("recent"))

        #expect(try await store.runTrashRetentionSweep() == 0)
        #expect(try await store.trashedTasks().count == 1)
    }
}
