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
}
