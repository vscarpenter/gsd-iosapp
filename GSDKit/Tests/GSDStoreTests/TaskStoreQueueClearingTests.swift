import Testing
import Foundation
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

    /// Records the order of the reminder cancel and the removal of queued writes.
    final class Order: @unchecked Sendable { var events: [String] = [] }
    struct OrderedReminders: ReminderScheduling {
        let order: Order
        func schedule(_ task: Task) async {}
        func cancel(taskID: String) async { order.events.append("cancel") }
        func cancelAll() async {}
        func requestAuthorizationIfNeeded() async -> Bool { false }
        func setBadge(_ count: Int) async {}
    }
    final class OrderedQueue: SyncQueueRepository, @unchecked Sendable {
        let base: GRDBSyncQueueRepository; let order: Order
        init(_ base: GRDBSyncQueueRepository, _ order: Order) { self.base = base; self.order = order }
        func enqueue(_ item: SyncQueueItem) async throws { try await base.enqueue(item) }
        func enqueueClearingWrites(_ item: SyncQueueItem) async throws { try await base.enqueueClearingWrites(item) }
        func pending() async throws -> [SyncQueueItem] { try await base.pending() }
        func update(_ item: SyncQueueItem) async throws { try await base.update(item) }
        func remove(id: String) async throws { order.events.append("remove"); try await base.remove(id: id) }
        func allTaskIds() async throws -> Set<String> { try await base.allTaskIds() }
        func all() async throws -> [SyncQueueItem] { try await base.all() }
    }

    @Test("trash cancels the reminder before it removes the task's queued writes")
    func trashCancelsTheReminderFirst() async throws {
        let db = try AppDatabase.inMemory()
        let base = GRDBSyncQueueRepository(db)
        let tasks = GRDBTaskRepository(db)
        let order = Order()
        let store = TaskStore(repository: tasks, smartViewRepository: GRDBSmartViewRepository(db),
                              archiveRepository: GRDBArchiveRepository(db), trashRepository: GRDBTrashRepository(db),
                              defaults: UserDefaults(suiteName: "clear.\(UUID().uuidString)")!,
                              clock: { Date(timeIntervalSince1970: 1_800_000_000) },
                              reminders: OrderedReminders(order: order), syncQueue: OrderedQueue(base, order))
        try await tasks.upsert(task("a"))
        try await base.enqueue(SyncQueueItem(id: "u-a", taskId: "a", operation: .update, timestamp: 1, payload: task("a")))
        try await store.delete(task("a"))
        #expect(order.events == ["cancel", "remove"])
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
