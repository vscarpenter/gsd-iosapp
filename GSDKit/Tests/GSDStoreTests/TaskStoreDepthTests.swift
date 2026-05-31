import Testing
import Foundation
import GSDModel
@testable import GSDStore

@MainActor
struct TaskStoreDepthTests {
    private let fixed = Date(timeIntervalSince1970: 1_700_000_000)

    private func utcCalendar() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func makeStore() throws -> (TaskStore, GRDBTaskRepository) {
        let repo = GRDBTaskRepository(try AppDatabase.inMemory(), now: { Date(timeIntervalSince1970: 1_700_000_000) })
        nonisolated(unsafe) var ids = ["spawned-id", "spawned-id-2"]
        let store = TaskStore(
            repository: repo,
            clock: { Date(timeIntervalSince1970: 1_700_000_000) },
            newID: { ids.isEmpty ? "fallback" : ids.removeFirst() },
            calendar: utcCalendar()
        )
        return (store, repo)
    }

    private func dueDate(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d; c.hour = 12
        return utcCalendar().date(from: c)!
    }

    @Test func completingRecurringTaskSpawnsAdvancedInstance() async throws {
        let (store, repo) = try makeStore()
        let original = Task(id: "orig", title: "Standup", urgent: true, important: true,
                            createdAt: fixed, updatedAt: fixed,
                            dueDate: dueDate(2026, 1, 31), recurrence: .monthly,
                            subtasks: [Subtask(id: "s1", title: "review", completed: true)])
        try await repo.upsert(original)
        try await store.toggleComplete(original)

        // Original is now completed and retained.
        let done = try #require(try await repo.fetch(id: "orig"))
        #expect(done.completed && done.completedAt == fixed)

        // A new instance exists with the advanced (clamped) due date + reset subtasks.
        let spawned = try #require(try await repo.fetch(id: "spawned-id"))
        #expect(spawned.completed == false)
        #expect(spawned.recurrence == .monthly)
        #expect(spawned.parentTaskId == "orig")
        let cal = utcCalendar()
        let due = cal.dateComponents([.year, .month, .day], from: try #require(spawned.dueDate))
        #expect((due.year, due.month, due.day) == (2026, 2, 28)) // Jan 31 + 1mo clamp
        #expect(spawned.subtasks.allSatisfy { !$0.completed })
    }

    @Test func completingNonRecurringTaskSpawnsNothing() async throws {
        let (store, repo) = try makeStore()
        let task = Task(id: "orig", title: "One-off", urgent: false, important: false,
                        createdAt: fixed, updatedAt: fixed, recurrence: .none)
        try await repo.upsert(task)
        try await store.toggleComplete(task)
        #expect(try await repo.fetch(id: "spawned-id") == nil)
        #expect(try await repo.fetchAll().count == 1)
    }

    @Test func uncompletingRecurringTaskDoesNotSpawn() async throws {
        let (store, repo) = try makeStore()
        let task = Task(id: "orig", title: "Standup", urgent: true, important: true,
                        completed: true, completedAt: fixed,
                        createdAt: fixed, updatedAt: fixed,
                        dueDate: dueDate(2026, 1, 31), recurrence: .monthly)
        try await repo.upsert(task)
        try await store.toggleComplete(task) // completing → completed becomes false
        #expect(try await repo.fetch(id: "orig")?.completed == false)
        #expect(try await repo.fetch(id: "spawned-id") == nil)
    }
}
