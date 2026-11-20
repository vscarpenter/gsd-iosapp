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
                              trashRepository: GRDBTrashRepository(db, now: { Date(timeIntervalSince1970: 0) }),
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
        let data = try await store.exportJSON()
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

    /// Forwards every call to the real repository except `replaceAll`, which fails.
    final class FailingReplaceRepository: TaskRepository {
        struct Refused: Error {}
        let base: GRDBTaskRepository
        init(_ base: GRDBTaskRepository) { self.base = base }
        func upsert(_ task: Task) async throws { try await base.upsert(task) }
        func fetchAll() async throws -> [Task] { try await base.fetchAll() }
        func fetch(id: String) async throws -> Task? { try await base.fetch(id: id) }
        func setNotifyBeforeIfNull(id: String, value: Int) async throws { try await base.setNotifyBeforeIfNull(id: id, value: value) }
        func restampIfUnchanged(id: String, from: Date, to: Date) async throws -> Bool {
            try await base.restampIfUnchanged(id: id, from: from, to: to)
        }
        func delete(id: String) async throws { try await base.delete(id: id) }
        func replaceAll(_ tasks: [Task]) async throws { throw Refused() }
        func observeAll() -> AsyncThrowingStream<[Task], Error> { base.observeAll() }
    }

    /// A store with a real queue and two live tasks. `r`'s update was sent, failed once, and is waiting
    /// out its backoff. `k` has an update that hasn't been sent. The rows have distinct times, so the
    /// queue's order is fixed.
    private func storeWithQueuedWrites(failingReplace: Bool = false) async throws -> (TaskStore, GRDBSyncQueueRepository) {
        let db = try AppDatabase.inMemory()
        let tasks = GRDBTaskRepository(db)
        let queue = GRDBSyncQueueRepository(db)
        let store = TaskStore(repository: failingReplace ? FailingReplaceRepository(tasks) : tasks,
                              smartViewRepository: GRDBSmartViewRepository(db),
                              archiveRepository: GRDBArchiveRepository(db),
                              trashRepository: GRDBTrashRepository(db),
                              defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!,
                              clock: { Date(timeIntervalSince1970: 1000) },
                              syncQueue: queue)
        try await tasks.upsert(task("r"))
        try await tasks.upsert(task("k"))
        try await queue.enqueue(SyncQueueItem(id: "q-r", taskId: "r", operation: .update, timestamp: 100_000,
                                              retryCount: 1, payload: task("r"), lastError: "boom", lastAttemptAt: 900_000))
        try await queue.enqueue(SyncQueueItem(id: "q-k", taskId: "k", operation: .update, timestamp: 200_000,
                                              payload: task("k")))
        return (store, queue)
    }

    @Test("Import Replace clears the queued writes of the tasks it removes")
    func replaceClearsRemovedTasksWrites() async throws {
        let (store, queue) = try await storeWithQueuedWrites()
        let backup = try TaskExport.encode(TaskExport(tasks: [task("k")], exportedAt: Date(timeIntervalSince1970: 0)))
        try await store.importTasks(backup, mode: .replace)
        let rows = try await queue.all()
        let removed = rows.filter { $0.taskId == "r" }.map(\.operation)
        let kept = rows.filter { $0.taskId == "k" }
        #expect(removed == [.delete])
        #expect(kept.contains { $0.id == "q-k" })                                          // an imported id clears nothing
        #expect(kept.contains { $0.operation == .update && $0.timestamp == 1_000_000 })    // the import's own update
    }

    /// Passes before the fix too. It pins the rollback, which now also has to put the cleared rows back.
    @Test("a failed Import Replace leaves the queue exactly as it was")
    func failedReplaceRestoresTheQueue() async throws {
        let (store, queue) = try await storeWithQueuedWrites(failingReplace: true)
        let before = try await queue.all()
        let backup = try TaskExport.encode(TaskExport(tasks: [task("k")], exportedAt: Date(timeIntervalSince1970: 0)))
        await #expect(throws: FailingReplaceRepository.Refused.self) {
            try await store.importTasks(backup, mode: .replace)
        }
        #expect(try await queue.all() == before)
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

    @Test func eraseAllDataClearsTheFeedbackDraftAndSubmissionID() async throws {
        // B-16: web `resetFeedbackState()` clears the draft, its submission id and the sent
        // marker. Erase All Data must not leave a half-written message behind.
        let db = try AppDatabase.inMemory()
        let feedback = UserDefaults(suiteName: "test-feedback-\(UUID().uuidString)")!
        feedback.set(Data("draft".utf8), forKey: FeedbackLocalState.Key.draft)
        feedback.set("sub-123", forKey: FeedbackLocalState.Key.submissionID)
        feedback.set(1_700_000_000.0, forKey: FeedbackLocalState.Key.lastSentAt)
        let store = TaskStore(repository: GRDBTaskRepository(db),
                              smartViewRepository: GRDBSmartViewRepository(db),
                              archiveRepository: GRDBArchiveRepository(db),
                              trashRepository: GRDBTrashRepository(db),
                              defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!,
                              feedbackDefaults: feedback,
                              clock: { Date(timeIntervalSince1970: 1000) })
        try await store.eraseAllData()
        #expect(feedback.object(forKey: FeedbackLocalState.Key.draft) == nil)
        #expect(feedback.object(forKey: FeedbackLocalState.Key.submissionID) == nil)
        #expect(feedback.object(forKey: FeedbackLocalState.Key.lastSentAt) == nil)
    }

    /// Resurrect on sight, rule 2: the ids of tasks deleted while signed out are device-local, and
    /// Erase all data forgets them, or an erased task could come back at the next sign-in.
    @Test("erasing local data forgets every remembered id")
    func erasingLocalDataForgetsEveryRememberedId() async throws {
        let db = try AppDatabase.inMemory()
        let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        defaults.set(["t1", "t2"], forKey: AppGroupDefaults.Key.resurrectOnSight)
        let store = TaskStore(repository: GRDBTaskRepository(db),
                              smartViewRepository: GRDBSmartViewRepository(db),
                              archiveRepository: GRDBArchiveRepository(db),
                              trashRepository: GRDBTrashRepository(db),
                              defaults: defaults,
                              clock: { Date(timeIntervalSince1970: 1000) })

        try await store.eraseAllData()

        #expect(defaults.object(forKey: AppGroupDefaults.Key.resurrectOnSight) == nil)
    }

    @Test func eraseAllDataClearsTheSyncQueue() async throws {
        // A signed-out user's mutations all enqueue; an erase that leaves them queued would
        // re-create every "erased" task on the server (and then locally) at the next sign-in.
        let db = try AppDatabase.inMemory()
        let queue = GRDBSyncQueueRepository(db)
        let store = TaskStore(repository: GRDBTaskRepository(db),
                              smartViewRepository: GRDBSmartViewRepository(db),
                              archiveRepository: GRDBArchiveRepository(db),
                              trashRepository: GRDBTrashRepository(db),
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
