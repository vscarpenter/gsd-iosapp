import Foundation
import GRDB
import GSDModel

/// Async persistence for the push queue (§7.5). Holds NO business rules. Built in 5a; WIRED to
/// `TaskStore` mutations in 5c. `pending()` returns only `.pending` items (the push loop drains
/// these); `.failed` items stay in the table for manual retry and are surfaced separately later.
public protocol SyncQueueRepository: Sendable {
    func enqueue(_ item: SyncQueueItem) async throws
    func pending() async throws -> [SyncQueueItem]     // status == .pending, ordered by timestamp asc
    /// Rewrites an existing row. A row that has been removed stays removed: a push that read its queue
    /// before an archive or Trash cleared a task's writes must not put one back by recording a failure.
    func update(_ item: SyncQueueItem) async throws
    func remove(id: String) async throws
    /// Queues a task's delete and removes that task's create and update rows in one write, so a failure
    /// leaves neither half behind. Every conformer implements it; none may fall back to two writes.
    func enqueueClearingWrites(_ item: SyncQueueItem) async throws
    func allTaskIds() async throws -> Set<String>      // pending + failed
    func all() async throws -> [SyncQueueItem]          // every item (pending + failed), timestamp asc — health checks (5d)
}

public final class GRDBSyncQueueRepository: SyncQueueRepository {
    private let dbWriter: any DatabaseWriter

    public init(_ database: AppDatabase) {
        self.dbWriter = database.writer
    }

    public func enqueue(_ item: SyncQueueItem) async throws {
        let record = try SyncQueueRecord(item)
        try await dbWriter.write { db in try record.save(db) }
    }

    public func pending() async throws -> [SyncQueueItem] {
        try await dbWriter.read { db in
            try SyncQueueRecord
                .filter(Column("status") == SyncQueueItem.Status.pending.rawValue)
                .order(Column("timestamp"))
                .fetchAll(db)
                .map { try $0.toDomain() }
        }
    }

    public func update(_ item: SyncQueueItem) async throws {
        let record = try SyncQueueRecord(item)
        try await dbWriter.write { db in
            do { try record.update(db) } catch PersistenceError.recordNotFound { }   // removed since the caller read it
        }
    }

    public func enqueueClearingWrites(_ item: SyncQueueItem) async throws {
        let record = try SyncQueueRecord(item)
        try await dbWriter.write { db in
            try record.save(db)
            _ = try SyncQueueRecord
                .filter(Column("taskId") == item.taskId && Column("operation") != SyncQueueItem.Operation.delete.rawValue)
                .deleteAll(db)
        }
    }

    public func remove(id: String) async throws {
        try await dbWriter.write { db in _ = try SyncQueueRecord.deleteOne(db, key: id) }
    }

    public func allTaskIds() async throws -> Set<String> {
        try await dbWriter.read { db in
            Set(try SyncQueueRecord.fetchAll(db).map(\.taskId))
        }
    }

    public func all() async throws -> [SyncQueueItem] {
        try await dbWriter.read { db in
            try SyncQueueRecord.order(Column("timestamp")).fetchAll(db).map { try $0.toDomain() }
        }
    }
}

/// The default queue for `TaskStore` when no real sync is wired (mirrors `NoopReminderScheduler`).
public struct NoopSyncQueueRepository: SyncQueueRepository {
    public init() {}
    public func enqueue(_ item: SyncQueueItem) async throws {}
    public func pending() async throws -> [SyncQueueItem] { [] }
    public func update(_ item: SyncQueueItem) async throws {}
    public func enqueueClearingWrites(_ item: SyncQueueItem) async throws {}
    public func remove(id: String) async throws {}
    public func allTaskIds() async throws -> Set<String> { [] }
    public func all() async throws -> [SyncQueueItem] { [] }
}
