import Foundation
import GRDB
import GSDModel

/// Async persistence boundary for tasks. Holds NO business rules.
///
/// Responsibility split for `updatedAt`:
/// - The caller (Phase 1 use-case/store layer) stamps `updatedAt` on the PRIMARY
///   mutation (upsert) with its own injected clock — the repository never touches
///   it there (increment spec §3.3, product spec §5.1).
/// - The repository stamps `updatedAt` on CASCADE SIDE-EFFECTS it originates —
///   specifically, the dependency-scrub rows produced by `delete` (§6.8). The
///   caller can't know which rows were scrubbed, so the repository owns that stamp
///   via its own injected clock (`now`).
public protocol TaskRepository: Sendable {
    func upsert(_ task: Task) async throws
    func fetchAll() async throws -> [Task]
    func fetch(id: String) async throws -> Task?
    /// One write that sets only `notifyBefore`, and only where it is still null (D-10). The sync
    /// drain settles a legacy null this way, so a local write that lands in between is never
    /// reverted by a whole-row save. Touches no other column, not even `updatedAt`.
    func setNotifyBeforeIfNull(id: String, value: Int) async throws
    /// One write that sets only `updatedAt` to `to`, and only where the row's stamp still equals `from`
    /// to the millisecond. Push uses it to record the stamp a bumped write sent, so a local edit made
    /// since is never reverted. Returns whether it wrote. Touches no other column.
    func restampIfUnchanged(id: String, from: Date, to: Date) async throws -> Bool
    func delete(id: String) async throws
    /// Replace the entire task table in a single transaction: delete all rows, then insert
    /// `tasks`. Erase All Data uses it with no tasks. No dependency-scrub is needed (a full clear
    /// leaves no surviving rows that could reference a deleted id).
    func replaceAll(_ tasks: [Task]) async throws
    /// Import Replace, as one write: queue `items`, remove the queued creates and updates of every task
    /// in `removedIds`, and replace the task table with `tasks`. A create or update left queued for a
    /// removed task would come due after its delete landed and POST the task back. If the write fails,
    /// the tasks and the queue stay exactly as they were. This writes the queue rows through the task
    /// repository's own database writer. The task repository and the sync queue must therefore share
    /// one database, which `App/GSDApp.swift` does.
    func replaceAll(_ tasks: [Task], queueing items: [SyncQueueItem], clearingWritesFor removedIds: Set<String>) async throws
    func observeAll() -> AsyncThrowingStream<[Task], Error>
}

public final class GRDBTaskRepository: TaskRepository {
    private let dbWriter: any DatabaseWriter
    private let now: @Sendable () -> Date
    private let observerQueue = DispatchQueue(label: "dev.vinny.gsd.task-observer")

    public init(_ database: AppDatabase, now: @escaping @Sendable () -> Date = { Date() }) {
        self.dbWriter = database.writer
        self.now = now
    }

    public func upsert(_ task: Task) async throws {
        let record = try TaskRecord(task)
        try await dbWriter.write { db in try record.save(db) }
    }

    public func fetchAll() async throws -> [Task] {
        try await dbWriter.read { db in
            try TaskRecord.order(Column("updatedAt").desc).fetchAll(db).map { try $0.toDomain() }
        }
    }

    public func fetch(id: String) async throws -> Task? {
        try await dbWriter.read { db in
            guard let record = try TaskRecord.fetchOne(db, key: id) else { return nil }
            return try record.toDomain()
        }
    }

    public func setNotifyBeforeIfNull(id: String, value: Int) async throws {
        try await dbWriter.write { db in
            try db.execute(sql: "UPDATE tasks SET notifyBefore = ? WHERE id = ? AND notifyBefore IS NULL",
                           arguments: [value, id])
        }
    }

    public func restampIfUnchanged(id: String, from: Date, to: Date) async throws -> Bool {
        try await dbWriter.write { db in
            guard let record = try TaskRecord.fetchOne(db, key: id),
                  Self.ms(record.updatedAt) == Self.ms(from) else { return false }
            try db.execute(sql: "UPDATE tasks SET updatedAt = ? WHERE id = ?", arguments: [to, id])
            return true
        }
    }

    // Rounds, not truncates: GRDB's .datetime and the queue's JSON both round to the millisecond, and their read-back Dates differ below it.
    private static func ms(_ date: Date) -> Int { Int((date.timeIntervalSince1970 * 1000).rounded()) }

    public func delete(id: String) async throws {
        let scrubTimestamp = now()
        try await dbWriter.write { db in
            // O(n) scrub: scans every row to strip the deleted id from `dependencies`.
            // This relies on every row's `dependencies` being well-formed JSON (guaranteed
            // by the NOT NULL DEFAULT '[]' column constraint + all writes going through
            // TaskRecord). A malformed row would throw here and abort the whole transaction.
            // YAGNI: a targeted index-based approach is not worth the added complexity yet.
            //
            // `updatedAt` is stamped here (via injected clock) because this repository
            // originates the scrub — the caller can't know which rows were affected.
            for var record in try TaskRecord.fetchAll(db) where record.id != id {
                var deps = try GSDJSON.value([String].self, record.dependencies)
                guard deps.contains(id) else { continue }
                deps.removeAll { $0 == id }
                record.dependencies = try GSDJSON.string(deps)
                record.updatedAt = scrubTimestamp
                try record.update(db, columns: ["dependencies", "updatedAt"])
            }
            _ = try TaskRecord.deleteOne(db, key: id)
        }
    }

    public func replaceAll(_ tasks: [Task]) async throws {
        let records = try tasks.map { try TaskRecord($0) }
        try await dbWriter.write { db in
            _ = try TaskRecord.deleteAll(db)
            for record in records { try record.insert(db) }
        }
    }

    public func replaceAll(_ tasks: [Task], queueing items: [SyncQueueItem], clearingWritesFor removedIds: Set<String>) async throws {
        let records = try tasks.map { try TaskRecord($0) }
        let queued = try items.map { try SyncQueueRecord($0) }
        try await dbWriter.write { db in
            for item in queued { try item.save(db) }
            _ = try SyncQueueRecord
                .filter(removedIds.contains(Column("taskId")) && Column("operation") != SyncQueueItem.Operation.delete.rawValue)
                .deleteAll(db)
            _ = try TaskRecord.deleteAll(db)
            for record in records { try record.insert(db) }
        }
    }

    public func observeAll() -> AsyncThrowingStream<[Task], Error> {
        AsyncThrowingStream { continuation in
            let observation = ValueObservation.tracking { db in
                try TaskRecord.order(Column("updatedAt").desc).fetchAll(db).map { try $0.toDomain() }
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
