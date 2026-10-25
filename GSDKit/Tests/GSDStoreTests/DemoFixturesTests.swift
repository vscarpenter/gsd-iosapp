import Foundation
import Testing
import GSDModel
@testable import GSDStore

/// The demo seed once deleted every task in a store. These pin the fence that keeps it off real
/// data: it fills an empty store and refuses any other, whatever the other holds.
@MainActor
struct DemoFixturesTests {
    /// The harness epoch, 2026-09-11 17:00 UTC.
    private let epoch = Date(timeIntervalSince1970: 1_789_146_000)

    private func makeStore() throws -> (TaskStore, GRDBTaskRepository, GRDBSyncQueueRepository) {
        let db = try AppDatabase.inMemory()
        let clock: @Sendable () -> Date = { Date(timeIntervalSince1970: 1_789_146_000) }
        let repo = GRDBTaskRepository(db, now: clock)
        let queue = GRDBSyncQueueRepository(db)
        let store = TaskStore(repository: repo,
                              smartViewRepository: GRDBSmartViewRepository(db),
                              archiveRepository: GRDBArchiveRepository(db, now: clock),
                              trashRepository: GRDBTrashRepository(db, now: clock),
                              defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!,
                              clock: clock,
                              syncQueue: queue)
        return (store, repo, queue)
    }

    private func realTask() -> Task {
        Task(id: "real-task", title: "Renew the plates", urgent: true, important: true,
             completed: false, completedAt: nil, createdAt: epoch, updatedAt: epoch,
             dueDate: nil, recurrence: .none, tags: [], subtasks: [], dependencies: [])
    }

    /// The incident's shape: fixtures from an earlier run beside real tasks. Nothing moves.
    @Test func seedRefusesAStoreThatHoldsFixturesBesideARealTask() async throws {
        let (store, repo, queue) = try makeStore()
        try await store.create(DemoFixtures.tasks(now: epoch)[0])
        try await store.create(realTask())
        let queuedBefore = try await queue.all().count

        await #expect(throws: DemoFixtures.SeedError.storeNotEmpty) {
            try await DemoFixtures.seed(into: store, now: epoch)
        }

        let remaining = try await repo.fetchAll()
        #expect(Set(remaining.map(\.id)) == ["demo-finance", "real-task"])
        #expect(try await queue.all().count == queuedBefore)
    }

    @Test func seedRefusesAStoreThatHoldsOnlyARealTask() async throws {
        let (store, repo, queue) = try makeStore()
        try await store.create(realTask())
        let queuedBefore = try await queue.all().count

        await #expect(throws: DemoFixtures.SeedError.storeNotEmpty) {
            try await DemoFixtures.seed(into: store, now: epoch)
        }

        #expect(try await repo.fetchAll().map(\.id) == ["real-task"])
        #expect(try await queue.all().count == queuedBefore)
    }

    @Test func seedFillsAnEmptyStoreWithEveryFixture() async throws {
        let (store, repo, _) = try makeStore()

        try await DemoFixtures.seed(into: store, now: epoch)

        let seeded = try await repo.fetchAll()
        #expect(seeded.count == 24)
        #expect(seeded.filter(\.completed).count == 14)
        #expect(Set(seeded.map(\.id)) == DemoFixtures.ids)
    }

    /// Every harness launch opens a fresh store, so a second seed in one store is a mistake, and
    /// the seed has no delete path left to make it look like a re-record.
    @Test func aSecondSeedIsRefusedAndChangesNothing() async throws {
        let (store, repo, queue) = try makeStore()
        try await DemoFixtures.seed(into: store, now: epoch)
        let queuedBefore = try await queue.all().count

        await #expect(throws: DemoFixtures.SeedError.storeNotEmpty) {
            try await DemoFixtures.seed(into: store, now: epoch)
        }

        let seeded = try await repo.fetchAll()
        #expect(seeded.count == 24)
        #expect(Set(seeded.map(\.id)) == DemoFixtures.ids)
        #expect(try await queue.all().count == queuedBefore)
    }
}
