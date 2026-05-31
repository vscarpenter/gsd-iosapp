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

    @Test func completingFromStaleCompletedSnapshotDoesNotDoubleSpawn() async throws {
        let (store, repo) = try makeStore()
        // Persisted row is ALREADY completed (e.g. a prior complete already spawned).
        let persisted = Task(id: "orig", title: "Standup", urgent: true, important: true,
                             completed: true, completedAt: fixed,
                             createdAt: fixed, updatedAt: fixed,
                             dueDate: dueDate(2026, 1, 31), recurrence: .monthly)
        try await repo.upsert(persisted)
        // Caller holds a STALE snapshot that still thinks the task is incomplete
        // (the @Observable store lags the async write). A double-fired "complete"
        // looks exactly like this.
        var stale = persisted
        stale.completed = false
        try await store.toggleComplete(stale)
        // Ground truth says it was already complete, so this is a true→false toggle,
        // NOT a completion — no duplicate recurrence instance may be spawned.
        #expect(try await repo.fetch(id: "spawned-id") == nil)
        #expect(try await repo.fetch(id: "orig")?.completed == false)
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

    @Test func addSubtaskAppendsIncompleteItem() async throws {
        let (store, repo) = try makeStore()
        let task = Task(id: "orig", title: "Trip", urgent: false, important: true,
                        createdAt: fixed, updatedAt: fixed)
        try await repo.upsert(task)
        try await store.addSubtask(to: task, title: "Pack bags")
        let updated = try #require(try await repo.fetch(id: "orig"))
        #expect(updated.subtasks.map(\.title) == ["Pack bags"])
        #expect(updated.subtasks[0].completed == false)
        #expect(updated.updatedAt == fixed)
    }

    @Test func toggleSubtaskFlipsCompletion() async throws {
        let (store, repo) = try makeStore()
        var task = Task(id: "orig", title: "Trip", urgent: false, important: true,
                        createdAt: fixed, updatedAt: fixed)
        task.subtasks = [Subtask(id: "s1", title: "Pack", completed: false)]
        try await repo.upsert(task)
        try await store.toggleSubtask(in: task, subtaskID: "s1")
        #expect(try await repo.fetch(id: "orig")?.subtasks.first?.completed == true)
    }

    @Test func deleteSubtaskRemovesIt() async throws {
        let (store, repo) = try makeStore()
        var task = Task(id: "orig", title: "Trip", urgent: false, important: true,
                        createdAt: fixed, updatedAt: fixed)
        task.subtasks = [Subtask(id: "s1", title: "A"), Subtask(id: "s2", title: "B")]
        try await repo.upsert(task)
        try await store.deleteSubtask(in: task, subtaskID: "s1")
        #expect(try await repo.fetch(id: "orig")?.subtasks.map(\.id) == ["s2"])
    }

    @Test func moveSubtaskReorders() async throws {
        let (store, repo) = try makeStore()
        var task = Task(id: "orig", title: "Trip", urgent: false, important: true,
                        createdAt: fixed, updatedAt: fixed)
        task.subtasks = [Subtask(id: "s1", title: "A"), Subtask(id: "s2", title: "B"),
                         Subtask(id: "s3", title: "C")]
        try await repo.upsert(task)
        // Move the item at index 2 ("C") to the front.
        try await store.moveSubtask(in: task, fromOffsets: IndexSet(integer: 2), toOffset: 0)
        #expect(try await repo.fetch(id: "orig")?.subtasks.map(\.id) == ["s3", "s1", "s2"])
    }

    @Test func moveSubtaskStraddlingMultiSelect() async throws {
        // Covers the straddling multi-index case: indices {0, 4} moved to toOffset 2
        // over a 5-element list. SwiftUI's move yields [B, A, E, C, D].
        let (store, repo) = try makeStore()
        var task = Task(id: "orig", title: "Trip", urgent: false, important: true,
                        createdAt: fixed, updatedAt: fixed)
        task.subtasks = [Subtask(id: "A", title: "A"), Subtask(id: "B", title: "B"),
                         Subtask(id: "C", title: "C"), Subtask(id: "D", title: "D"),
                         Subtask(id: "E", title: "E")]
        try await repo.upsert(task)
        try await store.moveSubtask(in: task, fromOffsets: IndexSet([0, 4]), toOffset: 2)
        #expect(try await repo.fetch(id: "orig")?.subtasks.map(\.id) == ["B", "A", "E", "C", "D"])
    }

    @Test func addDependencyValidatesAndPersists() async throws {
        let (store, repo) = try makeStore()
        let now = fixed
        try await repo.upsert(Task(id: "A", title: "A", urgent: true, important: true,
                                   createdAt: now, updatedAt: now))
        try await repo.upsert(Task(id: "B", title: "B", urgent: true, important: true,
                                   createdAt: now, updatedAt: now))
        store.start()
        var waited = 0
        while store.tasks.count < 2 && waited < 100 {
            try await _Concurrency.Task.sleep(for: .milliseconds(10)); waited += 1
        }
        let a = try #require(store.tasks.first { $0.id == "A" })
        try await store.addDependency("B", to: a)
        #expect(try await repo.fetch(id: "A")?.dependencies == ["B"])
    }

    @Test func addDependencyRejectsCycle() async throws {
        let (store, repo) = try makeStore()
        let now = fixed
        // A depends on B already; adding A as a dependency of B closes a cycle.
        try await repo.upsert(Task(id: "A", title: "A", urgent: true, important: true,
                                   createdAt: now, updatedAt: now, dependencies: ["B"]))
        try await repo.upsert(Task(id: "B", title: "B", urgent: true, important: true,
                                   createdAt: now, updatedAt: now))
        store.start()
        var waited = 0
        while store.tasks.count < 2 && waited < 100 {
            try await _Concurrency.Task.sleep(for: .milliseconds(10)); waited += 1
        }
        let b = try #require(store.tasks.first { $0.id == "B" })
        await #expect(throws: DependencyError.cycle) {
            try await store.addDependency("A", to: b)
        }
        #expect(try await repo.fetch(id: "B")?.dependencies == [])
    }

    @Test func removeDependencyDropsIt() async throws {
        let (store, repo) = try makeStore()
        let task = Task(id: "A", title: "A", urgent: true, important: true,
                        createdAt: fixed, updatedAt: fixed, dependencies: ["B", "C"])
        try await repo.upsert(task)
        try await store.removeDependency("B", from: task)
        #expect(try await repo.fetch(id: "A")?.dependencies == ["C"])
    }
}
