import Foundation
import GRDB
import GSDModel

/// Async persistence boundary for CUSTOM smart views. Holds no business rules; the
/// caller (TaskStore) stamps `createdAt`/`updatedAt`. Ordered by `updatedAt` desc to
/// match the task repository's convention.
public protocol SmartViewRepository: Sendable {
    func upsert(_ view: SmartView, createdAt: Date, updatedAt: Date) async throws
    func fetchAll() async throws -> [SmartView]
    func delete(id: String) async throws
    func observeAll() -> AsyncThrowingStream<[SmartView], Error>
}

public final class GRDBSmartViewRepository: SmartViewRepository {
    private let dbWriter: any DatabaseWriter
    private let observerQueue = DispatchQueue(label: "dev.vinny.gsd.smartview-observer")

    public init(_ database: AppDatabase) { self.dbWriter = database.writer }

    public func upsert(_ view: SmartView, createdAt: Date, updatedAt: Date) async throws {
        let record = try SmartViewRecord(view, createdAt: createdAt, updatedAt: updatedAt)
        try await dbWriter.write { db in try record.save(db) }
    }

    public func fetchAll() async throws -> [SmartView] {
        try await dbWriter.read { db in
            try SmartViewRecord.order(Column("updatedAt").desc).fetchAll(db).map { try $0.toDomain() }
        }
    }

    public func delete(id: String) async throws {
        _ = try await dbWriter.write { db in try SmartViewRecord.deleteOne(db, key: id) }
    }

    public func observeAll() -> AsyncThrowingStream<[SmartView], Error> {
        AsyncThrowingStream { continuation in
            let observation = ValueObservation.tracking { db in
                try SmartViewRecord.order(Column("updatedAt").desc).fetchAll(db).map { try $0.toDomain() }
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
