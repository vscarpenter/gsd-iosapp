import Foundation
import GRDB
import GSDModel

/// Async persistence boundary for tasks. Holds NO business rules. The spec rule
/// "every mutation bumps `updatedAt`" (increment spec §3.3, product spec §5.1) is
/// satisfied one layer up: the Phase 1 use-case/store layer stamps `updatedAt`
/// with an injected clock before calling `upsert`, so the repository itself never
/// injects time. `delete` also strips the id from every other task's
/// `dependencies` (product spec §6.8 cleanup-on-delete).
public protocol TaskRepository: Sendable {
    func upsert(_ task: Task) async throws
    func fetchAll() async throws -> [Task]
    func fetch(id: String) async throws -> Task?
    func delete(id: String) async throws
    func observeAll() -> AsyncThrowingStream<[Task], Error>
}

public final class GRDBTaskRepository: TaskRepository {
    private let dbWriter: any DatabaseWriter
    private let observerQueue = DispatchQueue(label: "dev.vinny.gsd.task-observer")

    public init(_ database: AppDatabase) {
        self.dbWriter = database.writer
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
        try await dbWriter.write { db in
            for var record in try TaskRecord.fetchAll(db) where record.id != id {
                var deps = try GSDJSON.value([String].self, record.dependencies)
                guard deps.contains(id) else { continue }
                deps.removeAll { $0 == id }
                record.dependencies = try GSDJSON.string(deps)
                try record.update(db, columns: ["dependencies"])
            }
            _ = try TaskRecord.deleteOne(db, key: id)
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
