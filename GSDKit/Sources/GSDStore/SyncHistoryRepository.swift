import Foundation
import GRDB

/// Async persistence for sync history (§7.7). Holds no business rules; the engine builds the
/// entries. `recent` is timestamp-desc; `prune` bounds the table. Mirrors the other GRDB repos.
public protocol SyncHistoryRepository: Sendable {
    func insert(_ entry: SyncHistoryEntry) async throws
    func recent(limit: Int) async throws -> [SyncHistoryEntry]
    func stats() async throws -> SyncHistoryStats
    func prune(keeping: Int) async throws
}

public final class GRDBSyncHistoryRepository: SyncHistoryRepository {
    private let dbWriter: any DatabaseWriter
    public init(_ database: AppDatabase) { self.dbWriter = database.writer }

    public func insert(_ entry: SyncHistoryEntry) async throws {
        let record = SyncHistoryRecord(entry)
        try await dbWriter.write { db in try record.save(db) }
    }

    public func recent(limit: Int) async throws -> [SyncHistoryEntry] {
        try await dbWriter.read { db in
            try SyncHistoryRecord.order(Column("timestamp").desc).limit(limit).fetchAll(db).map { $0.toDomain() }
        }
    }

    public func stats() async throws -> SyncHistoryStats {
        try await dbWriter.read { db in
            let all = try SyncHistoryRecord.fetchAll(db)
            return SyncHistoryStats(
                totalSyncs: all.count,
                successes: all.filter { $0.status == SyncHistoryEntry.Status.success.rawValue }.count,
                totalPushed: all.reduce(0) { $0 + $1.pushedCount },
                totalPulled: all.reduce(0) { $0 + $1.pulledCount })
        }
    }

    public func prune(keeping: Int) async throws {
        try await dbWriter.write { db in
            let survivors = try SyncHistoryRecord.order(Column("timestamp").desc).limit(keeping)
                .fetchAll(db).map(\.id)
            try SyncHistoryRecord.filter(!survivors.contains(Column("id"))).deleteAll(db)
        }
    }
}

/// Default no-op for `TaskStore`/`SyncEngine` when history isn't wired (tests / offline).
public struct NoopSyncHistoryRepository: SyncHistoryRepository {
    public init() {}
    public func insert(_ entry: SyncHistoryEntry) async throws {}
    public func recent(limit: Int) async throws -> [SyncHistoryEntry] { [] }
    public func stats() async throws -> SyncHistoryStats { SyncHistoryStats() }
    public func prune(keeping: Int) async throws {}
}
