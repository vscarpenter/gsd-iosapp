import Foundation
import GRDB
import GSDModel

/// Async persistence for the push queue (§7.5). Holds NO business rules. Built in 5a; WIRED to
/// `TaskStore` mutations in 5c. `pending()` returns only `.pending` items (the push loop drains
/// these); `.failed` items stay in the table for manual retry and are surfaced separately later.
public protocol SyncQueueRepository: Sendable {
    func enqueue(_ item: SyncQueueItem) async throws
    func pending() async throws -> [SyncQueueItem]     // status == .pending, ordered by timestamp asc
    func update(_ item: SyncQueueItem) async throws
    func remove(id: String) async throws
    func allTaskIds() async throws -> Set<String>      // pending + failed — both protect from deletion-reconcile (5c)
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
        try await dbWriter.write { db in try record.save(db) }   // save = insert-or-update by primary key
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
    public func remove(id: String) async throws {}
    public func allTaskIds() async throws -> Set<String> { [] }
    public func all() async throws -> [SyncQueueItem] { [] }
}
