import Testing
import Foundation
import GSDModel
@testable import GSDStore

@MainActor
struct TaskStoreFilterTests {
    private func utcCalendar() -> Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }
    /// now = 2026-06-15 09:00 UTC
    private let now = { () -> Date in
        var c = DateComponents(); c.year = 2026; c.month = 6; c.day = 15; c.hour = 9
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: c)!
    }()

    private func makeStore() throws -> (TaskStore, GRDBTaskRepository) {
        let repo = GRDBTaskRepository(try AppDatabase.inMemory(), now: { Date(timeIntervalSince1970: 0) })
        let fixed = now
        let store = TaskStore(repository: repo, clock: { fixed }, calendar: utcCalendar())
        return (store, repo)
    }
    private func waitForTasks(_ store: TaskStore, count: Int) async throws {
        store.start()
        var waited = 0
        while store.tasks.count < count && waited < 100 {
            try await _Concurrency.Task.sleep(for: .milliseconds(10)); waited += 1
        }
    }

    @Test func tasksMatchingFiltersByCriteria() async throws {
        let (store, repo) = try makeStore()
        try await repo.upsert(Task(id: "active", title: "A", urgent: true, important: true,
                                   createdAt: now, updatedAt: now))
        try await repo.upsert(Task(id: "done", title: "B", urgent: true, important: true,
                                   completed: true, completedAt: now, createdAt: now, updatedAt: now))
        try await waitForTasks(store, count: 2)
        let active = store.tasks(matching: FilterCriteria(status: .active))
        #expect(active.map(\.id) == ["active"])
    }

    @Test func tasksMatchingUsesInjectedClockForDatePredicates() async throws {
        let (store, repo) = try makeStore()
        // Build due dates in UTC (matching the store's injected calendar).
        func due(_ y: Int, _ m: Int, _ d: Int) -> Date {
            var c = DateComponents(); c.year = y; c.month = m; c.day = d; c.hour = 12
            var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
            return cal.date(from: c)!
        }
        // Store clock = 2026-06-15 09:00 UTC. due 6/14 is overdue; 6/20 is not.
        try await repo.upsert(Task(id: "overdue", title: "O", urgent: true, important: true,
                                   createdAt: now, updatedAt: now, dueDate: due(2026, 6, 14)))
        try await repo.upsert(Task(id: "future", title: "F", urgent: true, important: true,
                                   createdAt: now, updatedAt: now, dueDate: due(2026, 6, 20)))
        try await waitForTasks(store, count: 2)
        // `overdue` is resolved against the store's INJECTED clock (2026-06-15), not Date().
        #expect(store.tasks(matching: FilterCriteria(overdue: true)).map(\.id) == ["overdue"])
    }
}
