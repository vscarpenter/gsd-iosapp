import Foundation
import GRDB
import GSDModel

/// Async persistence boundary for trashed tasks. `trash`/`restore` move a row between the
/// `tasks` and `deletedTasks` tables in a single transaction so the two never both hold (or
/// both drop) the same id — the same invariant `ArchiveRepository` keeps. `deletedAt` is
/// stamped from the injected clock.
public protocol TrashRepository: Sendable {
    func trash(_ task: Task) async throws
    /// Trash with an EXPLICIT stamp, for restoring a backup: re-stamping with `now()` would
    /// reset every trashed row's age and hand the user back a full 30 days they had spent.
    func trash(_ task: Task, at deletedAt: Date) async throws
    /// Move a row back to `tasks`. No-op when the id is not in the trash.
    func restore(id: String) async throws -> Task?
    func deleteForever(id: String) async throws
    func empty() async throws -> Int
    func fetchAll() async throws -> [Task]
    /// Trashed rows WITH their `deletedAt` stamp — for the backup envelope and for the
    /// retention sweep, both of which need to know how old a row is.
    func fetchAllStamped() async throws -> [ArchivedTask]
    /// Drop every row stamped strictly before `cutoff`. Returns how many were purged.
    func purge(before cutoff: Date) async throws -> Int
    func observeAll() -> AsyncThrowingStream<[Task], Error>
}

public final class GRDBTrashRepository: TrashRepository {
    private let dbWriter: any DatabaseWriter
    private let now: @Sendable () -> Date
    private let observerQueue = DispatchQueue(label: "dev.vinny.gsd.trash-observer")

    public init(_ database: AppDatabase, now: @escaping @Sendable () -> Date = { Date() }) {
        self.dbWriter = database.writer
        self.now = now
    }

    public func trash(_ task: Task) async throws {
        try await trash(task, at: now())
    }

    public func trash(_ task: Task, at deletedAt: Date) async throws {
        let record = try DeletedTaskRecord(task, deletedAt: deletedAt)
        try await dbWriter.write { db in
            try record.save(db)
            _ = try TaskRecord.deleteOne(db, key: task.id)
        }
    }

    public func restore(id: String) async throws -> Task? {
        try await dbWriter.write { db in
            guard let trashed = try DeletedTaskRecord.fetchOne(db, key: id) else { return nil }
            let task = try trashed.toDomain()
            try TaskRecord(task).save(db)
            _ = try DeletedTaskRecord.deleteOne(db, key: id)
            return task
        }
    }

    public func deleteForever(id: String) async throws {
        _ = try await dbWriter.write { db in try DeletedTaskRecord.deleteOne(db, key: id) }
    }

    public func empty() async throws -> Int {
        try await dbWriter.write { db in try DeletedTaskRecord.deleteAll(db) }
    }

    public func fetchAll() async throws -> [Task] {
        try await dbWriter.read { db in
            try DeletedTaskRecord.order(Column("deletedAt").desc).fetchAll(db).map { try $0.toDomain() }
        }
    }

    public func fetchAllStamped() async throws -> [ArchivedTask] {
        try await dbWriter.read { db in
            try DeletedTaskRecord.order(Column("deletedAt").desc).fetchAll(db).map {
                ArchivedTask(task: try $0.toDomain(), stampedAt: $0.deletedAt, stampKey: .deletedAt)
            }
        }
    }

    public func purge(before cutoff: Date) async throws -> Int {
        try await dbWriter.write { db in
            try DeletedTaskRecord.filter(Column("deletedAt") < cutoff).deleteAll(db)
        }
    }

    public func observeAll() -> AsyncThrowingStream<[Task], Error> {
        AsyncThrowingStream { continuation in
            let observation = ValueObservation.tracking { db in
                try DeletedTaskRecord.order(Column("deletedAt").desc).fetchAll(db).map { try $0.toDomain() }
            }
            let cancellable = observation.start(
                in: dbWriter,
                scheduling: .async(onQueue: observerQueue),
                onError: { continuation.finish(throwing: $0) },
                onChange: { continuation.yield($0) }
            )
            continuation.onTermination = { _ in cancellable.cancel() }
        }
    }
}
