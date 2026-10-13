import Foundation
import GRDB
import GSDModel

/// The archive and the trash, read as sync tombstones (parity S9). A task id sits in exactly one
/// of `tasks`, `archivedTasks`, or `deletedTasks`. Sync asks when a task was archived or trashed,
/// and a remote copy edited after that moves the task back to the live table in one write, so the
/// id is never in two tables.
public protocol TombstoneRepository: Sendable {
    /// When the task was archived or trashed, or nil when it is in neither table.
    func tombstoneDate(id: String) async throws -> Date?
    /// Drop the archived or trashed row and save `task` as live, in one transaction.
    func resurrect(_ task: Task) async throws
}

public final class GRDBTombstoneRepository: TombstoneRepository {
    private let dbWriter: any DatabaseWriter

    public init(_ database: AppDatabase) {
        self.dbWriter = database.writer
    }

    public func tombstoneDate(id: String) async throws -> Date? {
        try await dbWriter.read { db in
            let archivedAt = try ArchivedTaskRecord.fetchOne(db, key: id)?.archivedAt
            let deletedAt = try DeletedTaskRecord.fetchOne(db, key: id)?.deletedAt
            return [archivedAt, deletedAt].compactMap { $0 }.max()
        }
    }

    public func resurrect(_ task: Task) async throws {
        let record = try TaskRecord(task)
        try await dbWriter.write { db in
            _ = try ArchivedTaskRecord.deleteOne(db, key: task.id)
            _ = try DeletedTaskRecord.deleteOne(db, key: task.id)
            try record.save(db)
        }
    }
}
