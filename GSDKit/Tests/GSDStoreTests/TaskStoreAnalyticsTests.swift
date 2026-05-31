import Testing
import Foundation
import GSDModel
@testable import GSDStore

@MainActor
struct TaskStoreAnalyticsTests {
    /// now = 2026-06-15 09:00 UTC (matches the engine fixtures).
    private let now: Date = {
        var c = DateComponents(); c.year = 2026; c.month = 6; c.day = 15; c.hour = 9
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: c)!
    }()
    private func utcCalendar() -> Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }
    private func makeStore() throws -> TaskStore {
        let db = try AppDatabase.inMemory()
        let fixed = now
        return TaskStore(repository: GRDBTaskRepository(db),
                         smartViewRepository: GRDBSmartViewRepository(db),
                         archiveRepository: GRDBArchiveRepository(db, now: { Date(timeIntervalSince1970: 0) }),
                         defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!,
                         clock: { fixed }, calendar: utcCalendar())
    }
    private func waitForTasks(_ store: TaskStore, count: Int) async throws {
        store.start()
        var waited = 0
        while store.tasks.count != count && waited < 200 {
            try await _Concurrency.Task.sleep(for: .milliseconds(10)); waited += 1
        }
    }

    @Test func analyticsComputesOverLiveSnapshotWithStoreClock() async throws {
        let store = try makeStore()
        store.start()
        try await store.create(Task(id: "a", title: "A", urgent: true, important: true,
                                    createdAt: now, updatedAt: now))
        try await store.create(Task(id: "b", title: "B", urgent: false, important: false,
                                    completed: true, completedAt: now, createdAt: now, updatedAt: now))
        try await waitForTasks(store, count: 2)
        let summary = store.analytics(trendDays: 7)
        #expect(summary.totalCount == 2 && summary.completedCount == 1)
        #expect(summary.trend.count == 7)
        #expect(summary.trend.last?.created == 2)   // both created "today" via the store clock
    }
}
