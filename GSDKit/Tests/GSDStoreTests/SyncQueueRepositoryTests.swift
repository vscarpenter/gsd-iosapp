import Testing
import Foundation
import GSDModel
@testable import GSDStore

struct SyncQueueRepositoryTests {
    private func makeRepo() throws -> GRDBSyncQueueRepository {
        GRDBSyncQueueRepository(try AppDatabase.inMemory())
    }
    private func sampleTask(_ id: String) -> Task {
        Task(id: id, title: "t", urgent: false, important: false,
             createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
    }

    @Test func enqueueAndFetchPendingRoundTripsPayload() async throws {
        let repo = try makeRepo()
        try await repo.enqueue(SyncQueueItem(id: "q1", taskId: "task-1", operation: .create,
                                             timestamp: 100, payload: sampleTask("task-1")))
        let pending = try await repo.pending()
        #expect(pending.count == 1)
        #expect(pending[0].id == "q1")
        #expect(pending[0].operation == .create)
        #expect(pending[0].payload?.id == "task-1")     // Task payload survived the JSON round-trip
    }

    @Test func deleteOperationHasNilPayload() async throws {
        let repo = try makeRepo()
        try await repo.enqueue(SyncQueueItem(id: "q-del", taskId: "task-9", operation: .delete,
                                             timestamp: 50, payload: nil))
        let pending = try await repo.pending()
        #expect(pending[0].operation == .delete)
        #expect(pending[0].payload == nil)              // nil payload round-trips as SQL NULL
    }

    @Test func pendingIsOrderedByTimestamp() async throws {
        let repo = try makeRepo()
        try await repo.enqueue(SyncQueueItem(id: "b", taskId: "t", operation: .update, timestamp: 200))
        try await repo.enqueue(SyncQueueItem(id: "a", taskId: "t", operation: .update, timestamp: 100))
        #expect(try await repo.pending().map(\.id) == ["a", "b"])
    }

    @Test func failedItemsAreExcludedFromPendingButRetained() async throws {
        let repo = try makeRepo()
        var item = SyncQueueItem(id: "q1", taskId: "t", operation: .create, timestamp: 100)
        try await repo.enqueue(item)
        item.status = .failed; item.retryCount = 5; item.lastError = "boom"; item.failedAt = 999
        try await repo.update(item)
        #expect(try await repo.pending().isEmpty)       // failed → not drained by pending()
        item.status = .pending                          // retained, not dropped — re-mark and it returns
        try await repo.update(item)
        let back = try await repo.pending()
        #expect(back.count == 1 && back[0].retryCount == 5 && back[0].lastError == "boom")
    }

    @Test func removeDeletesTheItem() async throws {
        let repo = try makeRepo()
        try await repo.enqueue(SyncQueueItem(id: "q1", taskId: "t", operation: .update, timestamp: 100))
        try await repo.remove(id: "q1")
        #expect(try await repo.pending().isEmpty)
    }

    @Test func v4MigrationCoexistsWithEarlierTables() async throws {
        let db = try AppDatabase.inMemory()              // runs v1–v4
        let taskRepo = GRDBTaskRepository(db)
        try await taskRepo.upsert(sampleTask("task-1"))
        let queueRepo = GRDBSyncQueueRepository(db)
        try await queueRepo.enqueue(SyncQueueItem(id: "q1", taskId: "task-1", operation: .create,
                                                  timestamp: 1, payload: sampleTask("task-1")))
        #expect(try await taskRepo.fetchAll().count == 1)
        #expect(try await queueRepo.pending().count == 1)
    }

    @Test func allTaskIdsReturnsPendingAndFailed() async throws {
        let repo = try makeRepo()
        try await repo.enqueue(SyncQueueItem(id: "q1", taskId: "t1", operation: .create, timestamp: 1))
        var failed = SyncQueueItem(id: "q2", taskId: "t2", operation: .update, timestamp: 2)
        failed.status = .failed
        try await repo.update(failed)   // upsert as failed
        #expect(try await repo.allTaskIds() == ["t1", "t2"])   // both states protect from reconcile
    }

    @Test func noopRepositoryDoesNothing() async throws {
        let noop = NoopSyncQueueRepository()
        try await noop.enqueue(SyncQueueItem(id: "x", taskId: "t", operation: .create, timestamp: 1))
        #expect(try await noop.pending().isEmpty)
        #expect(try await noop.allTaskIds().isEmpty)
    }
}
