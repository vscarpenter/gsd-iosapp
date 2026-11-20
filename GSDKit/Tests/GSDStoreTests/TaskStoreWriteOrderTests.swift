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
        func setNotifyBeforeIfNull(id: String, value: Int) async throws {}
        func restampIfUnchanged(id: String, from: Date, to: Date) async throws -> Bool { false }
        func delete(id: String) async throws { log.events.append("delete") }
        func replaceAll(_ tasks: [Task]) async throws { log.events.append("replaceAll") }
        func replaceAll(_ tasks: [Task], queueing items: [SyncQueueItem], deletingLeftOut makeDelete: @Sendable (String) -> SyncQueueItem) async throws {
            log.events.append("replaceAllQueueing")
        }
        func observeAll() -> AsyncThrowingStream<[Task], Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    /// Delete is a soft delete, so its local write is the move into the trash, not
    /// `TaskRepository.delete`. That one call also queues the delete, so the delete tests below
    /// check for the single call. Without this double they would pass vacuously.
    final class LoggingTrash: TrashRepository, @unchecked Sendable {
        let log: EventLog
        var failTrash = false
        struct Boom: Error {}
        init(log: EventLog) { self.log = log }
        func trash(_ task: Task) async throws { try await trash(task, at: Date()) }
        func trash(_ task: Task, at deletedAt: Date) async throws {
            log.events.append("trash")
            if failTrash { throw Boom() }
        }
        func trash(_ task: Task, at deletedAt: Date, queueing item: SyncQueueItem) async throws {
            log.events.append("trashQueueing")
            if failTrash { throw Boom() }
        }
        func restore(id: String, queueing makeItem: @Sendable (Task) -> SyncQueueItem) async throws -> Task? {
            log.events.append("restoreFromTrash")
            return nil
        }
        func deleteForever(id: String) async throws {}
        func empty() async throws -> Int { 0 }
        func fetchAll() async throws -> [Task] { [] }
        func fetchAllStamped() async throws -> [ArchivedTask] { [] }
        func purge(before cutoff: Date) async throws -> Int { 0 }
        func observeAll() -> AsyncThrowingStream<[Task], Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    /// Archiving deletes the server copy too (parity B-43), so the move into the archive is
    /// ordered against the delete's enqueue, like the move into the trash.
    final class LoggingArchive: ArchiveRepository, @unchecked Sendable {
        let log: EventLog
        var failArchive = false
        struct Boom: Error {}
        init(log: EventLog) { self.log = log }
        func archive(_ task: Task) async throws { try await archive(task, at: Date()) }
        func archive(_ task: Task, at archivedAt: Date) async throws {
            log.events.append("archive")
            if failArchive { throw Boom() }
        }
        func restore(id: String) async throws { log.events.append("restore") }
        func deletePermanently(id: String) async throws {}
        func fetchAll() async throws -> [Task] { [] }
        func fetchAllStamped() async throws -> [ArchivedTask] { [] }
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
        func enqueueClearingWrites(_ item: SyncQueueItem) async throws { try await enqueue(item) }
        func enqueueIfLive(_ item: SyncQueueItem) async throws -> Bool { try await enqueue(item); return true }
        func pending() async throws -> [SyncQueueItem] { items }
        func update(_ item: SyncQueueItem) async throws {}
        func remove(id: String) async throws { log.events.append("remove"); items.removeAll { $0.id == id } }
        func allTaskIds() async throws -> Set<String> { Set(items.map(\.taskId)) }
        func all() async throws -> [SyncQueueItem] { items }
    }

    private func makeStore(repo: LoggingRepository, queue: LoggingQueue,
                           trash: LoggingTrash? = nil, archive: LoggingArchive? = nil) throws -> TaskStore {
        let db = try AppDatabase.inMemory()
        return TaskStore(repository: repo,
                         smartViewRepository: GRDBSmartViewRepository(db),
                         archiveRepository: archive ?? LoggingArchive(log: repo.log),
                         trashRepository: trash ?? LoggingTrash(log: repo.log),
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

    /// Trash queues its delete in the same write that moves the row, so there is no order
    /// between two writes left to get wrong, and nothing goes through the injected queue.
    @Test func deleteQueuesAndTrashesInOneCall() async throws {
        let log = EventLog()
        let queue = LoggingQueue(log: log)
        let store = try makeStore(repo: LoggingRepository(log: log), queue: queue)
        try await store.delete(task("a"))
        #expect(log.events == ["trashQueueing"])
        #expect(queue.items.isEmpty)
    }

    /// Import Replace queues its rows and swaps the task table in one write, so no push can run between
    /// its queue writes and its task write, and nothing goes through the injected queue. This replaces
    /// the sync-level `importReplaceWindow`, which pushed inside that window.
    @Test func replaceQueuesAndSwapsInOneCall() async throws {
        let log = EventLog()
        let queue = LoggingQueue(log: log)
        let store = try makeStore(repo: LoggingRepository(log: log), queue: queue)
        let backup = try TaskExport.encode(TaskExport(tasks: [task("a")], exportedAt: Date(timeIntervalSince1970: 0)))
        try await store.importTasks(backup, mode: .replace)
        #expect(log.events == ["replaceAllQueueing"])
        #expect(queue.items.isEmpty)
    }

    /// A delete that isn't recorded must keep the local row. An upsert's row survives a failed
    /// enqueue and the next sync's seed re-queues it, but a trashed row is gone, so the next pull
    /// would resurrect the task. The one write lands whole or not at all, and the store reports it.
    @Test func aFailedTrashWriteIsDeleteNotRecorded() async throws {
        let log = EventLog()
        let trash = LoggingTrash(log: log); trash.failTrash = true
        let queue = LoggingQueue(log: log)
        let store = try makeStore(repo: LoggingRepository(log: log), queue: queue, trash: trash)
        await #expect(throws: TaskStoreError.deleteNotRecorded) { try await store.delete(self.task("a")) }
        #expect(log.events == ["trashQueueing"])
        #expect(queue.items.isEmpty)
    }

    /// Archive is the reverse of delete: the row moves first, then the delete is queued. A
    /// failure between the two can then at worst leave an archived task whose server copy
    /// survives. Queuing first could leave a delete pending for a task that is still live, and
    /// after it pushed, deletion reconcile would remove that task with no archive or trash copy.
    @Test func archiveMovesTheRowBeforeQueuingTheDelete() async throws {
        let log = EventLog()
        let queue = LoggingQueue(log: log)
        let store = try makeStore(repo: LoggingRepository(log: log), queue: queue)
        try await store.archive(task("a"))
        #expect(log.events == ["archive", "enqueue"])
        #expect(queue.items.map(\.operation) == [.delete])
    }

    @Test func archivePutsTheTaskBackWhenTheDeleteCannotBeQueued() async throws {
        let log = EventLog()
        let queue = LoggingQueue(log: log); queue.failEnqueue = true
        let store = try makeStore(repo: LoggingRepository(log: log), queue: queue)
        await #expect(throws: TaskStoreError.archiveNotRecorded) { try await store.archive(self.task("a")) }
        #expect(log.events == ["archive", "restore"])                 // live again, server copy untouched
        #expect(queue.items.isEmpty)
    }

    @Test func aFailedArchiveQueuesNothing() async throws {
        let log = EventLog()
        let archive = LoggingArchive(log: log); archive.failArchive = true
        let queue = LoggingQueue(log: log)
        let store = try makeStore(repo: LoggingRepository(log: log), queue: queue, archive: archive)
        await #expect(throws: LoggingArchive.Boom.self) { try await store.archive(self.task("a")) }
        #expect(queue.items.isEmpty)                                  // the task stayed live, so no delete
        #expect(log.events == ["archive"])
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
