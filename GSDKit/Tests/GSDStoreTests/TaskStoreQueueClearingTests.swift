import Testing
import Foundation
import GRDB
import GSDModel
@testable import GSDStore

/// Archiving or trashing a task removes that task's queued creates and updates and nothing else.
@MainActor
struct TaskStoreQueueClearingTests {
    private final class Ticks: @unchecked Sendable {
        var next: Date; let step: TimeInterval
        init(from start: Date, step: TimeInterval) { next = start; self.step = step }
        func read() -> Date { defer { next = next.addingTimeInterval(step) }; return next }
    }

    /// A queue whose combined delete-and-clear write always fails.
    final class FailingClearQueue: SyncQueueRepository, @unchecked Sendable {
        let base: GRDBSyncQueueRepository
        init(_ base: GRDBSyncQueueRepository) { self.base = base }
        struct Refused: Error {}
        func enqueue(_ item: SyncQueueItem) async throws { try await base.enqueue(item) }
        func enqueueClearingWrites(_ item: SyncQueueItem) async throws { throw Refused() }
        func enqueueIfLive(_ item: SyncQueueItem) async throws -> Bool { try await base.enqueueIfLive(item) }
        func pending() async throws -> [SyncQueueItem] { try await base.pending() }
        func update(_ item: SyncQueueItem) async throws { try await base.update(item) }
        func remove(id: String) async throws { try await base.remove(id: id) }
        func allTaskIds() async throws -> Set<String> { try await base.allTaskIds() }
        func all() async throws -> [SyncQueueItem] { try await base.all() }
    }

    private func make(clock: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_800_000_000) },
                      wrap: (GRDBSyncQueueRepository) -> any SyncQueueRepository = { $0 })
        throws -> (TaskStore, GRDBSyncQueueRepository, GRDBTaskRepository) {
        let db = try AppDatabase.inMemory()
        let queue = GRDBSyncQueueRepository(db)
        let tasks = GRDBTaskRepository(db)
        let store = TaskStore(repository: tasks, smartViewRepository: GRDBSmartViewRepository(db),
                              archiveRepository: GRDBArchiveRepository(db), trashRepository: GRDBTrashRepository(db),
                              defaults: UserDefaults(suiteName: "clear.\(UUID().uuidString)")!,
                              clock: clock, syncQueue: wrap(queue))
        return (store, queue, tasks)
    }

    private func task(_ id: String) -> Task {
        Task(id: id, title: id, urgent: false, important: false,
             createdAt: Date(timeIntervalSince1970: 1_000), updatedAt: Date(timeIntervalSince1970: 1_000))
    }
    private func seed(_ tasks: GRDBTaskRepository, _ queue: GRDBSyncQueueRepository) async throws {
        for id in ["a", "b"] {
            try await tasks.upsert(task(id))
            try await queue.enqueue(SyncQueueItem(id: "c-\(id)", taskId: id, operation: .create, timestamp: 1, payload: task(id)))
            try await queue.enqueue(SyncQueueItem(id: "u-\(id)", taskId: id, operation: .update, timestamp: 2, payload: task(id)))
        }
    }

    @Test("archiving a task leaves another task's queued writes alone")
    func archiveKeepsOtherTasksWrites() async throws {
        let (store, queue, tasks) = try make()
        try await seed(tasks, queue)
        try await store.archive(task("a"))
        let rows = try await queue.all()
        #expect(rows.filter { $0.taskId == "a" }.map(\.operation) == [.delete])
        #expect(Set(rows.filter { $0.taskId == "b" }.map(\.id)) == ["c-b", "u-b"])
    }

    @Test("trashing a task leaves another task's queued writes alone")
    func trashKeepsOtherTasksWrites() async throws {
        let (store, queue, tasks) = try make()
        try await seed(tasks, queue)
        try await store.delete(task("a"))
        let rows = try await queue.all()
        #expect(rows.filter { $0.taskId == "a" }.map(\.operation) == [.delete])
        #expect(Set(rows.filter { $0.taskId == "b" }.map(\.id)) == ["c-b", "u-b"])
    }

    @Test("trash reads the clock once: the Trash time is the delete's queue time")
    func trashUsesOneClockReading() async throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000.0007)   // a sub-millisecond part, as a real clock has
        let ticks = Ticks(from: start, step: 0.005)
        let (store, queue, tasks) = try make(clock: { ticks.read() })
        try await tasks.upsert(task("a"))
        try await store.delete(task("a"))
        let trashedAt = try #require(try await store.trashedTasks().first).stampedAt
        let queued = try #require(try await queue.all().first)
        #expect(queued.timestamp == Int(start.timeIntervalSince1970 * 1000))   // truncated, as the queue stores it
        #expect(abs(trashedAt.timeIntervalSince(start)) < 0.001)               // the first reading, not a later one
    }

    /// A store over a database the test can reach, so it can make SQLite refuse a queue write.
    private struct Rig {
        let store: TaskStore
        let db: AppDatabase
        let queue: GRDBSyncQueueRepository
        let tasks: GRDBTaskRepository
    }

    private func rig(reminders: (AppDatabase) -> any ReminderScheduling) throws -> Rig {
        let db = try AppDatabase.inMemory()
        let queue = GRDBSyncQueueRepository(db)
        let tasks = GRDBTaskRepository(db)
        let store = TaskStore(repository: tasks, smartViewRepository: GRDBSmartViewRepository(db),
                              archiveRepository: GRDBArchiveRepository(db), trashRepository: GRDBTrashRepository(db),
                              defaults: UserDefaults(suiteName: "clear.\(UUID().uuidString)")!,
                              clock: { Date(timeIntervalSince1970: 1_800_000_000) },
                              reminders: reminders(db), syncQueue: queue)
        return Rig(store: store, db: db, queue: queue, tasks: tasks)
    }

    /// The queue write a trigger refuses: queuing the delete, or removing the task's queued writes.
    enum RefusedWrite: String, CaseIterable, Sendable { case insert = "INSERT", delete = "DELETE" }

    private func refuse(_ write: RefusedWrite, in db: AppDatabase) async throws {
        try await db.writer.write { db in
            try db.execute(sql: "CREATE TRIGGER refuseQueue BEFORE \(write.rawValue) ON syncQueue BEGIN SELECT RAISE(ABORT, 'refused'); END")
        }
    }

    private func seedWithUpdate(_ id: String, _ rig: Rig) async throws {
        try await rig.tasks.upsert(task(id))
        try await rig.queue.enqueue(SyncQueueItem(id: "u-\(id)", taskId: id, operation: .update, timestamp: 1, payload: task(id)))
    }

    @Test("a Trash whose queue write is refused leaves the task live with its queue, Trash, and reminder untouched",
          arguments: RefusedWrite.allCases)
    func trashIsOneWrite(refusing write: RefusedWrite) async throws {
        let reminders = RecordingReminderScheduler()
        let rig = try rig(reminders: { _ in reminders })
        try await seedWithUpdate("a", rig)
        try await refuse(write, in: rig.db)

        await #expect(throws: TaskStoreError.deleteNotRecorded) { try await rig.store.delete(task("a")) }

        let live = try await rig.tasks.fetch(id: "a")
        let queued = try await rig.queue.all().filter { $0.taskId == "a" }.map(\.operation)
        let trashed = try await rig.store.trashedTasks()
        #expect(live != nil)
        #expect(queued == [.update])
        #expect(trashed.isEmpty)
        #expect(!reminders.calls.contains(.cancel("a")))
    }

    /// Records each reminder cancel with where the task was then. In Trash means the write had committed.
    final class Cancels: @unchecked Sendable { var events: [String] = [] }
    struct CommitCheckingReminders: ReminderScheduling {
        let cancels: Cancels
        let trash: GRDBTrashRepository
        func schedule(_ task: Task) async {}
        func cancel(taskID: String) async {
            let inTrash = (try? await trash.fetchAll())?.contains { $0.id == taskID } == true
            cancels.events.append(inTrash ? "cancel \(taskID) in Trash" : "cancel \(taskID) still live")
        }
        func cancelAll() async {}
        func requestAuthorizationIfNeeded() async -> Bool { false }
        func setBadge(_ count: Int) async {}
    }

    @Test("trash cancels the reminder once, after its write commits, and a failed Trash cancels nothing")
    func trashCancelsTheReminderOnlyAfterItCommits() async throws {
        let cancels = Cancels()
        let rig = try rig(reminders: { CommitCheckingReminders(cancels: cancels, trash: GRDBTrashRepository($0)) })
        try await seedWithUpdate("a", rig)
        try await seedWithUpdate("b", rig)

        try await rig.store.delete(task("a"))
        #expect(cancels.events == ["cancel a in Trash"])

        try await refuse(.delete, in: rig.db)   // the removal of b's queued update fails
        await #expect(throws: TaskStoreError.deleteNotRecorded) { try await rig.store.delete(task("b")) }
        #expect(cancels.events == ["cancel a in Trash"])
    }

    /// The real Trash, except that an edit to the task lands just before the Trash write, after the
    /// store built its copy. It queues its update, then saves the row, as a main-actor edit does.
    final class EditLandsBeforeTrash: TrashRepository, @unchecked Sendable {
        let base: GRDBTrashRepository, tasks: GRDBTaskRepository, queue: GRDBSyncQueueRepository
        init(_ db: AppDatabase) {
            base = GRDBTrashRepository(db); tasks = GRDBTaskRepository(db); queue = GRDBSyncQueueRepository(db)
        }
        func trash(_ task: Task) async throws { try await base.trash(task) }
        func trash(_ task: Task, at deletedAt: Date) async throws { try await base.trash(task, at: deletedAt) }
        func trash(_ task: Task, at deletedAt: Date, queueing item: SyncQueueItem) async throws {
            var edited = task
            edited.title = "edited"; edited.updatedAt = task.updatedAt.addingTimeInterval(60)
            try await queue.enqueue(SyncQueueItem(id: "u-edit", taskId: task.id, operation: .update, timestamp: 3, payload: edited))
            try await tasks.upsert(edited)
            try await base.trash(task, at: deletedAt, queueing: item)
        }
        func restore(id: String, queueing makeItem: @Sendable (Task) -> SyncQueueItem) async throws -> Task? {
            try await base.restore(id: id, queueing: makeItem)
        }
        func deleteForever(id: String) async throws { try await base.deleteForever(id: id) }
        func empty() async throws -> Int { try await base.empty() }
        func fetchAll() async throws -> [Task] { try await base.fetchAll() }
        func fetchAllStamped() async throws -> [ArchivedTask] { try await base.fetchAllStamped() }
        func purge(before cutoff: Date) async throws -> Int { try await base.purge(before: cutoff) }
        func observeAll() -> AsyncThrowingStream<[Task], Error> { base.observeAll() }
    }

    /// The Trash write clears the edit's queued update, so the Trash row is the only place left that can
    /// hold the edit. It must be built from the row the write moves, not the copy read before it.
    @Test("an edit landing just before the Trash write is the copy Trash keeps")
    func trashKeepsAnEditThatLandedBeforeItsWrite() async throws {
        let db = try AppDatabase.inMemory()
        let queue = GRDBSyncQueueRepository(db)
        let tasks = GRDBTaskRepository(db)
        let store = TaskStore(repository: tasks, smartViewRepository: GRDBSmartViewRepository(db),
                              archiveRepository: GRDBArchiveRepository(db), trashRepository: EditLandsBeforeTrash(db),
                              defaults: UserDefaults(suiteName: "clear.\(UUID().uuidString)")!,
                              clock: { Date(timeIntervalSince1970: 1_800_000_000) }, syncQueue: queue)
        try await tasks.upsert(task("a"))

        try await store.delete(task("a"))

        let trashed = try #require(try await store.trashedTasks().first).task
        #expect(trashed.title == "edited")
        #expect(trashed.updatedAt == task("a").updatedAt.addingTimeInterval(60))
        #expect(try await queue.all().map(\.operation) == [.delete])
        #expect(try await tasks.fetch(id: "a") == nil)
    }

    @Test("an archive whose delete can't be queued with its clearing returns the task to active and keeps the rows")
    func failedArchiveKeepsEverything() async throws {
        let (store, queue, tasks) = try make(wrap: { FailingClearQueue($0) })
        try await seed(tasks, queue)
        await #expect(throws: TaskStoreError.archiveNotRecorded) { try await store.archive(task("a")) }
        #expect(try await tasks.fetch(id: "a") != nil)
        #expect(Set(try await queue.all().filter { $0.taskId == "a" }.map(\.id)) == ["c-a", "u-a"])
    }

    @Test("updating a row that was removed does not bring it back")
    func updateDoesNotResurrect() async throws {
        let (_, queue, _) = try make()
        var item = SyncQueueItem(id: "q1", taskId: "a", operation: .update, timestamp: 1)
        try await queue.enqueue(item)
        try await queue.remove(id: "q1")
        item.retryCount = 1
        try await queue.update(item)
        #expect(try await queue.all().isEmpty)
    }
}
