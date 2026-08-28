import Foundation
import GRDB
import GSDModel

/// Async persistence boundary for archived tasks. `archive`/`restore` move a row between
/// the `tasks` and `archivedTasks` tables in a single transaction so the two never both
/// hold (or both drop) the same id. `archivedAt` is stamped from the injected clock.
public protocol ArchiveRepository: Sendable {
    func archive(_ task: Task) async throws
    /// Archive with an EXPLICIT stamp, for restoring a backup: re-stamping those rows with
    /// `now()` would reset every archived task's age and defeat the retention window.
    func archive(_ task: Task, at archivedAt: Date) async throws
    func restore(id: String) async throws
    func deletePermanently(id: String) async throws
    func fetchAll() async throws -> [Task]
    /// Archived rows WITH their `archivedAt` stamp. `fetchAll` drops it (the UI has no use
    /// for it); a backup does — dropping it there would restore the archive as live tasks.
    func fetchAllStamped() async throws -> [ArchivedTask]
    func observeAll() -> AsyncThrowingStream<[Task], Error>
}

public final class GRDBArchiveRepository: ArchiveRepository {
    private let dbWriter: any DatabaseWriter
    private let now: @Sendable () -> Date
    private let observerQueue = DispatchQueue(label: "dev.vinny.gsd.archive-observer")

    public init(_ database: AppDatabase, now: @escaping @Sendable () -> Date = { Date() }) {
        self.dbWriter = database.writer
        self.now = now
    }

    public func archive(_ task: Task) async throws {
        try await archive(task, at: now())
    }

    public func archive(_ task: Task, at archivedAt: Date) async throws {
        let record = try ArchivedTaskRecord(task, archivedAt: archivedAt)
        try await dbWriter.write { db in
            try record.save(db)
            _ = try TaskRecord.deleteOne(db, key: task.id)
        }
    }

    public func restore(id: String) async throws {
        try await dbWriter.write { db in
            guard let archived = try ArchivedTaskRecord.fetchOne(db, key: id) else { return }
            let task = try archived.toDomain()
            try TaskRecord(task).save(db)
            _ = try ArchivedTaskRecord.deleteOne(db, key: id)
        }
    }

    public func deletePermanently(id: String) async throws {
        _ = try await dbWriter.write { db in try ArchivedTaskRecord.deleteOne(db, key: id) }
    }

    public func fetchAll() async throws -> [Task] {
        try await dbWriter.read { db in
            try ArchivedTaskRecord.order(Column("archivedAt").desc).fetchAll(db).map { try $0.toDomain() }
        }
    }

    public func fetchAllStamped() async throws -> [ArchivedTask] {
        try await dbWriter.read { db in
            try ArchivedTaskRecord.order(Column("archivedAt").desc).fetchAll(db).map {
                ArchivedTask(task: try $0.toDomain(), stampedAt: $0.archivedAt, stampKey: .archivedAt)
            }
        }
    }

    public func observeAll() -> AsyncThrowingStream<[Task], Error> {
        AsyncThrowingStream { continuation in
            let observation = ValueObservation.tracking { db in
                try ArchivedTaskRecord.order(Column("archivedAt").desc).fetchAll(db).map { try $0.toDomain() }
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
