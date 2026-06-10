import Testing
import Foundation
import GSDModel
@testable import GSDStore

@MainActor
struct TaskStoreDataTests {
    private func makeStore() throws -> (TaskStore, AppDatabase) {
        let db = try AppDatabase.inMemory()
        let suite = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        let store = TaskStore(repository: GRDBTaskRepository(db),
                              smartViewRepository: GRDBSmartViewRepository(db),
                              archiveRepository: GRDBArchiveRepository(db, now: { Date(timeIntervalSince1970: 0) }),
                              defaults: suite,
                              clock: { Date(timeIntervalSince1970: 1000) },
                              newID: { "imp-fixed" },
                              calendar: .current)
        return (store, db)
    }
    private func waitForTasks(_ store: TaskStore, count: Int) async throws {
        store.start()
        var waited = 0
        while store.tasks.count != count && waited < 200 {
            try await _Concurrency.Task.sleep(for: .milliseconds(10)); waited += 1
        }
    }
    private func task(_ id: String) -> Task {
        Task(id: id, title: id, urgent: true, important: true,
             createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
    }

    @Test func exportThenImportReplaceRoundTrips() async throws {
        let (store, _) = try makeStore()
        store.start()
        try await store.create(task("a"))
        try await store.create(task("b"))
        try await waitForTasks(store, count: 2)
        let data = try store.exportJSON()
        try await store.importTasks(data, mode: .replace)
        try await waitForTasks(store, count: 2)
        #expect(Set(store.tasks.map(\.id)) == ["a", "b"])
    }
    @Test func importReplaceClearsExisting() async throws {
        let (store, _) = try makeStore()
        store.start()
        try await store.create(task("old"))
        try await waitForTasks(store, count: 1)
        let payload = try TaskExport.encode(TaskExport(tasks: [task("fresh")],
                                                       exportedAt: Date(timeIntervalSince1970: 0)))
        try await store.importTasks(payload, mode: .replace)
        // Replace keeps the count at 1 (old→fresh), so wait on CONTENT, not count: a
        // count-only wait returns before the observer delivers the new snapshot. Self-
        // verifying — if replaceAll failed to swap the row this times out and still fails.
        var waited = 0
        while store.tasks.map(\.id) != ["fresh"] && waited < 200 {
            try await _Concurrency.Task.sleep(for: .milliseconds(10)); waited += 1
        }
        #expect(store.tasks.map(\.id) == ["fresh"])
    }
    @Test func importMergeRegeneratesCollidingId() async throws {
        let (store, _) = try makeStore()
        store.start()
        try await store.create(task("a"))
        try await waitForTasks(store, count: 1)
        let payload = try TaskExport.encode(TaskExport(tasks: [task("a")],
                                                       exportedAt: Date(timeIntervalSince1970: 0)))
        try await store.importTasks(payload, mode: .merge)
        try await waitForTasks(store, count: 2)
        #expect(Set(store.tasks.map(\.id)) == ["a", "imp-fixed"])   // colliding id regenerated
    }
    @Test func eraseAllDataClearsTasksAndPinsButNotTheme() async throws {
        let (store, _) = try makeStore()
        store.start()
        try await store.create(task("a"))
        try await waitForTasks(store, count: 1)
        store.pin("overdue")
        try await store.eraseAllData()
        try await waitForTasks(store, count: 0)
        #expect(store.tasks.isEmpty)
        #expect(store.pinnedSmartViewIds.isEmpty)
    }

    @Test func eraseAllDataClearsTheSyncQueue() async throws {
        // A signed-out user's mutations all enqueue; an erase that leaves them queued would
        // re-create every "erased" task on the server (and then locally) at the next sign-in.
        let db = try AppDatabase.inMemory()
        let queue = GRDBSyncQueueRepository(db)
        let store = TaskStore(repository: GRDBTaskRepository(db),
                              smartViewRepository: GRDBSmartViewRepository(db),
                              archiveRepository: GRDBArchiveRepository(db),
                              defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!,
                              clock: { Date(timeIntervalSince1970: 1000) },
                              syncQueue: queue)
        try await store.create(task("a"))
        try await store.create(task("b"))
        #expect(try await queue.all().count == 2)
        try await store.eraseAllData()
        #expect(try await queue.all().isEmpty)
    }
}
