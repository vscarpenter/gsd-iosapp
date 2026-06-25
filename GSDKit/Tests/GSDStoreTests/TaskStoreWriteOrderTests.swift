import Testing
import Foundation
import GSDModel
@testable import GSDStore

/// Pins the Fix-E ordering invariant: the sync-queue item is persisted BEFORE the task row
/// (so deletion-reconcile can never see an unprotected new task), and an upsert failure
/// removes the orphaned queue item (an unpersisted task must not push a ghost create).
@MainActor
struct TaskStoreWriteOrderTests {
    final class EventLog: @unchecked Sendable { var events: [String] = [] }

    final class LoggingRepository: TaskRepository, @unchecked Sendable {
        let log: EventLog
        var failUpsert = false
        struct Boom: Error {}
        init(log: EventLog) { self.log = log }
        func upsert(_ task: Task) async throws {
            log.events.append("upsert")
            if failUpsert { throw Boom() }
        }
        func fetchAll() async throws -> [Task] { [] }
        func fetch(id: String) async throws -> Task? { nil }
        func delete(id: String) async throws { log.events.append("delete") }
        func replaceAll(_ tasks: [Task]) async throws { log.events.append("replaceAll") }
        func observeAll() -> AsyncThrowingStream<[Task], Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    final class LoggingQueue: SyncQueueRepository, @unchecked Sendable {
        let log: EventLog
        var items: [SyncQueueItem] = []
        var failEnqueue = false
        struct Boom: Error {}
        init(log: EventLog) { self.log = log }
        func enqueue(_ item: SyncQueueItem) async throws {
            if failEnqueue { throw Boom() }
            log.events.append("enqueue"); items.append(item)
        }
        func pending() async throws -> [SyncQueueItem] { items }
        func update(_ item: SyncQueueItem) async throws {}
        func remove(id: String) async throws { log.events.append("remove"); items.removeAll { $0.id == id } }
        func allTaskIds() async throws -> Set<String> { Set(items.map(\.taskId)) }
        func all() async throws -> [SyncQueueItem] { items }
    }

    private func makeStore(repo: LoggingRepository, queue: LoggingQueue) throws -> TaskStore {
        let db = try AppDatabase.inMemory()
        return TaskStore(repository: repo,
                         smartViewRepository: GRDBSmartViewRepository(db),
                         archiveRepository: GRDBArchiveRepository(db),
                         defaults: UserDefaults(suiteName: "t.\(UUID().uuidString)")!,
                         clock: { Date(timeIntervalSince1970: 1000) },
                         syncQueue: queue)
    }
    private func task(_ id: String) -> Task {
        Task(id: id, title: id, urgent: false, important: false,
             createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
    }

    @Test func createEnqueuesBeforeUpserting() async throws {
        let log = EventLog()
        let store = try makeStore(repo: LoggingRepository(log: log), queue: LoggingQueue(log: log))
        try await store.create(task("a"))
        #expect(log.events == ["enqueue", "upsert"])
    }

    @Test func deleteEnqueuesBeforeDeleting() async throws {
        let log = EventLog()
        let store = try makeStore(repo: LoggingRepository(log: log), queue: LoggingQueue(log: log))
        try await store.delete(task("a"))
        #expect(log.events == ["enqueue", "delete"])
    }

    /// A delete whose enqueue fails must NOT delete the local row: unlike an upsert (whose row
    /// survives and is re-enqueued by the next sync's seed), a deleted row is gone — seed cannot
    /// re-enqueue it, so a lost delete-enqueue lets the next pull resurrect the task. The delete
    /// must abort and keep the row so the user can retry.
    @Test func deleteAbortsAndKeepsRowWhenEnqueueFails() async throws {
        let log = EventLog()
        let repo = LoggingRepository(log: log)
        let queue = LoggingQueue(log: log); queue.failEnqueue = true
        let store = try makeStore(repo: repo, queue: queue)
        await #expect(throws: (any Error).self) { try await store.delete(self.task("a")) }
        #expect(!log.events.contains("delete"))   // local row NOT deleted → cannot resurrect
        #expect(queue.items.isEmpty)
    }

    @Test func failedUpsertRemovesTheOrphanedQueueItem() async throws {
        let log = EventLog()
        let repo = LoggingRepository(log: log); repo.failUpsert = true
        let queue = LoggingQueue(log: log)
        let store = try makeStore(repo: repo, queue: queue)
        await #expect(throws: LoggingRepository.Boom.self) { try await store.create(self.task("a")) }
        #expect(queue.items.isEmpty)                                  // orphan cleaned up
        #expect(log.events == ["enqueue", "upsert", "remove"])
    }
}
