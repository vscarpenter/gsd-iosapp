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
    func delete(id: String) async throws
    /// Replace the entire task table in a single transaction: delete all rows, then insert
    /// `tasks`. Used by Replace-mode import. No dependency-scrub is needed (a full clear
    /// leaves no surviving rows that could reference a deleted id).
    func replaceAll(_ tasks: [Task]) async throws
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
