import Testing
import Foundation
@testable import GSDStore

struct SyncHistoryRepositoryTests {
    private func makeRepo() throws -> GRDBSyncHistoryRepository {
        GRDBSyncHistoryRepository(try AppDatabase.inMemory())
    }
    private func entry(_ id: String, ts: Int, status: SyncHistoryEntry.Status = .success,
                       pushed: Int = 0, pulled: Int = 0) -> SyncHistoryEntry {
        SyncHistoryEntry(id: id, timestamp: ts, status: status, pushedCount: pushed,
                         pulledCount: pulled, deviceId: "dev-A", triggeredBy: .auto)
    }

    @Test func insertAndRecentRoundTripsNewestFirst() async throws {
        let repo = try makeRepo()
        try await repo.insert(entry("a", ts: 100))
        try await repo.insert(entry("b", ts: 300))
        try await repo.insert(entry("c", ts: 200))
        let recent = try await repo.recent(limit: 50)
        #expect(recent.map(\.id) == ["b", "c", "a"])      // timestamp desc
        #expect(recent[0].deviceId == "dev-A")
    }

    @Test func recentRespectsLimit() async throws {
        let repo = try makeRepo()
        for i in 0..<5 { try await repo.insert(entry("e\(i)", ts: i)) }
        #expect(try await repo.recent(limit: 2).count == 2)
    }

    @Test func statsAggregate() async throws {
        let repo = try makeRepo()
        try await repo.insert(entry("a", ts: 1, status: .success, pushed: 2, pulled: 1))
        try await repo.insert(entry("b", ts: 2, status: .error, pushed: 0, pulled: 0))
        try await repo.insert(entry("c", ts: 3, status: .success, pushed: 3, pulled: 4))
        let s = try await repo.stats()
        #expect(s == SyncHistoryStats(totalSyncs: 3, successes: 2, totalPushed: 5, totalPulled: 5))
    }

    @Test func pruneKeepsNewest() async throws {
        let repo = try makeRepo()
        for i in 0..<6 { try await repo.insert(entry("e\(i)", ts: i)) }
        try await repo.prune(keeping: 3)
        let kept = try await repo.recent(limit: 50).map(\.id)
        #expect(kept == ["e5", "e4", "e3"])
    }
}
