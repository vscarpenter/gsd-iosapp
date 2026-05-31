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

    @Test func snoozeSetsSnoozedUntilFromPreset() async throws {
        let (store, repo) = try makeStore()
        let task = Task(id: "orig", title: "Ping", urgent: true, important: false,
                        createdAt: fixed, updatedAt: fixed)
        try await repo.upsert(task)
        try await store.snooze(task, by: .oneHour)
        let updated = try #require(try await repo.fetch(id: "orig"))
        #expect(updated.snoozedUntil == fixed.addingTimeInterval(60 * 60))
        #expect(updated.updatedAt == fixed)
    }

    @Test func snoozeIsClampedToOneYearMax() async throws {
        let (store, repo) = try makeStore()
        let task = Task(id: "orig", title: "Ping", urgent: true, important: false,
                        createdAt: fixed, updatedAt: fixed)
        try await repo.upsert(task)
        // Custom interval beyond 1 year is clamped.
        try await store.snooze(task, by: .custom(FieldLimits.maxSnoozeInterval + 1_000_000))
        let updated = try #require(try await repo.fetch(id: "orig"))
        #expect(updated.snoozedUntil == fixed.addingTimeInterval(FieldLimits.maxSnoozeInterval))
    }

    @Test func startTimerAddsRunningEntry() async throws {
        let (store, repo) = try makeStore()
        let task = Task(id: "orig", title: "Work", urgent: true, important: true,
                        createdAt: fixed, updatedAt: fixed)
        try await repo.upsert(task)
        try await store.startTimer(task)
        let updated = try #require(try await repo.fetch(id: "orig"))
        #expect(updated.timeEntries.count == 1)
        #expect(updated.timeEntries[0].endedAt == nil)
    }

    @Test func startingSecondTimerThrows() async throws {
        let (store, repo) = try makeStore()
        var task = Task(id: "orig", title: "Work", urgent: true, important: true,
                        createdAt: fixed, updatedAt: fixed)
        task.timeEntries = [TimeEntry(id: "te000001", startedAt: fixed)]
        try await repo.upsert(task)
        await #expect(throws: TimeTrackingError.alreadyRunning) {
            try await store.startTimer(task)
        }
    }

    @Test func stopTimerClosesEntryAndRecalculatesTimeSpent() async throws {
        let (store, repo) = try makeStore()
        var task = Task(id: "orig", title: "Work", urgent: true, important: true,
                        createdAt: fixed, updatedAt: fixed)
        // Running entry started 5 minutes before "now".
        task.timeEntries = [TimeEntry(id: "te000001", startedAt: fixed.addingTimeInterval(-300))]
        try await repo.upsert(task)
        try await store.stopTimer(task)
        let updated = try #require(try await repo.fetch(id: "orig"))
        #expect(updated.timeEntries[0].endedAt == fixed)
        #expect(updated.timeSpent == 5)
    }
}
