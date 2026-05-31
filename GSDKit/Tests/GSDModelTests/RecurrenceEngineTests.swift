import Testing
import Foundation
@testable import GSDModel

struct RecurrenceEngineTests {
    /// A fixed UTC gregorian calendar so date math is deterministic.
    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var comps = DateComponents()
        comps.year = y; comps.month = m; comps.day = d; comps.hour = 12
        return cal.date(from: comps)!
    }

    private func ymd(_ date: Date) -> (Int, Int, Int) {
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return (c.year!, c.month!, c.day!)
    }

    @Test func dailyAdvancesOneDay() throws {
        let next = try #require(RecurrenceEngine.advance(date(2026, 1, 31), by: .daily, calendar: cal))
        #expect(ymd(next) == (2026, 2, 1))
    }

    @Test func weeklyAdvancesSevenDaysAcrossMonthBoundary() throws {
        let next = try #require(RecurrenceEngine.advance(date(2026, 1, 28), by: .weekly, calendar: cal))
        #expect(ymd(next) == (2026, 2, 4))
    }

    @Test func monthlyJan31ClampsToFebEndNonLeap() throws {
        let next = try #require(RecurrenceEngine.advance(date(2026, 1, 31), by: .monthly, calendar: cal))
        #expect(ymd(next) == (2026, 2, 28))
    }

    @Test func monthlyJan31ClampsToFeb29InLeapYear() throws {
        let next = try #require(RecurrenceEngine.advance(date(2024, 1, 31), by: .monthly, calendar: cal))
        #expect(ymd(next) == (2024, 2, 29))
    }

    @Test func monthlyMar31ClampsToApr30() throws {
        let next = try #require(RecurrenceEngine.advance(date(2026, 3, 31), by: .monthly, calendar: cal))
        #expect(ymd(next) == (2026, 4, 30))
    }

    @Test func noneReturnsNil() {
        #expect(RecurrenceEngine.advance(date(2026, 1, 31), by: .none, calendar: cal) == nil)
    }

    private func recurringTask() -> Task {
        let created = date(2026, 1, 1)
        return Task(
            id: "orig", title: "Water plants", description: "weekly",
            urgent: false, important: true,
            completed: true, completedAt: date(2026, 1, 31),
            createdAt: created, updatedAt: date(2026, 1, 31),
            dueDate: date(2026, 1, 31), recurrence: .monthly,
            tags: ["home"],
            subtasks: [Subtask(id: "s1", title: "fill can", completed: true),
                       Subtask(id: "s2", title: "mist leaves", completed: true)],
            dependencies: ["dep1"],
            notificationSent: true,
            lastNotificationAt: date(2026, 1, 30),
            snoozedUntil: date(2026, 2, 1),
            estimatedMinutes: 10,
            timeSpent: 12,
            timeEntries: [TimeEntry(id: "te000001", startedAt: date(2026, 1, 31))]
        )
    }

    @Test func spawnAdvancesDueDateAndAssignsNewIdentity() throws {
        let now = date(2026, 1, 31)
        let next = try #require(RecurrenceEngine.spawnNext(from: recurringTask(), now: now,
                                                           newID: "newid", calendar: cal))
        #expect(next.id == "newid")
        #expect(ymd(try #require(next.dueDate)) == (2026, 2, 28)) // monthly clamp
        #expect(next.createdAt == now && next.updatedAt == now)
        #expect(next.completed == false && next.completedAt == nil)
    }

    @Test func spawnResetsSubtasksToIncompleteKeepingTitlesAndOrder() throws {
        let next = try #require(RecurrenceEngine.spawnNext(from: recurringTask(), now: date(2026, 1, 31),
                                                           newID: "newid", calendar: cal))
        #expect(next.subtasks.map(\.title) == ["fill can", "mist leaves"])
        #expect(next.subtasks.allSatisfy { !$0.completed })
        // Subtask ids are regenerated so the spawned checklist is independent.
        #expect(next.subtasks.map(\.id) != ["s1", "s2"])
    }

    @Test func spawnResetsReminderAndTimeTrackingAndKeepsRecurrenceAndTagsAndDeps() throws {
        let next = try #require(RecurrenceEngine.spawnNext(from: recurringTask(), now: date(2026, 1, 31),
                                                           newID: "newid", calendar: cal))
        #expect(next.recurrence == .monthly)
        #expect(next.tags == ["home"])
        #expect(next.dependencies == ["dep1"])
        #expect(next.notificationSent == false)
        #expect(next.lastNotificationAt == nil)
        #expect(next.snoozedUntil == nil)
        #expect(next.timeSpent == nil)
        #expect(next.timeEntries.isEmpty)
    }

    @Test func spawnUsesRootIdForSingleLevelLineage() throws {
        // Original was itself a spawned instance (parentTaskId set). The new
        // instance must point at the ROOT, not chain off the instance.
        var instance = recurringTask()
        instance.id = "instance-2"
        instance.parentTaskId = "root-id"
        let next = try #require(RecurrenceEngine.spawnNext(from: instance, now: date(2026, 1, 31),
                                                           newID: "newid", calendar: cal))
        #expect(next.parentTaskId == "root-id")
    }

    @Test func spawnFromRootSetsParentToRootId() throws {
        // Original has no parent → it IS the root → child points at it.
        let next = try #require(RecurrenceEngine.spawnNext(from: recurringTask(), now: date(2026, 1, 31),
                                                           newID: "newid", calendar: cal))
        #expect(next.parentTaskId == "orig")
    }

    @Test func spawnWithNoDueDateStaysNoDueDate() throws {
        var t = recurringTask()
        t.dueDate = nil
        let next = try #require(RecurrenceEngine.spawnNext(from: t, now: date(2026, 1, 31),
                                                           newID: "newid", calendar: cal))
        #expect(next.dueDate == nil)
    }

    @Test func spawnReturnsNilForNonRecurringTask() {
        var t = recurringTask()
        t.recurrence = .none
        #expect(RecurrenceEngine.spawnNext(from: t, now: date(2026, 1, 31),
                                           newID: "newid", calendar: cal) == nil)
    }
}
