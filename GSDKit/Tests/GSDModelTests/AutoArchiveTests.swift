import Testing
import Foundation
@testable import GSDModel

struct AutoArchiveTests {
    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }()
    private func day(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 9) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d; c.hour = h
        return cal.date(from: c)!
    }
    /// now = 2026-06-15 09:00 UTC → startOfDay = 2026-06-15 00:00 UTC.
    private var now: Date { day(2026, 6, 15, 9) }
    /// cutoff at N=30 = 2026-05-16 00:00 UTC.
    private var cutoff: Date { cal.date(byAdding: .day, value: -30, to: cal.startOfDay(for: now))! }

    private func task(_ id: String, completed: Bool = true, completedAt: Date?) -> Task {
        Task(id: id, title: id, urgent: false, important: false, completed: completed,
             completedAt: completedAt, createdAt: Date(timeIntervalSince1970: 0),
             updatedAt: Date(timeIntervalSince1970: 0))
    }
    private func ids(_ tasks: [Task], days: Int = 30) -> Set<String> {
        Set(AutoArchive.tasksToArchive(tasks, afterDays: days, now: now, calendar: cal).map(\.id))
    }

    @Test func exactlyAtCutoffIsNotArchived() {
        #expect(ids([task("at", completedAt: cutoff)]).isEmpty)
    }
    @Test func oneSecondBeforeCutoffIsArchived() {
        #expect(ids([task("before", completedAt: cutoff.addingTimeInterval(-1))]) == ["before"])
    }
    @Test func oneSecondAfterCutoffIsNotArchived() {
        #expect(ids([task("after", completedAt: cutoff.addingTimeInterval(1))]).isEmpty)
    }
    @Test func completedOnTheNDaysAgoDayIsNotArchived() {
        // 2026-05-16 at 09:00 wall-clock is AFTER cutoff midnight → not yet old enough.
        #expect(ids([task("wall", completedAt: day(2026, 5, 16, 9))]).isEmpty)
    }
    @Test func completedTheDayBeforeIsArchived() {
        #expect(ids([task("dayBefore", completedAt: day(2026, 5, 15, 23))]) == ["dayBefore"])
    }
    @Test func incompleteNeverArchived() {
        #expect(ids([task("active", completed: false, completedAt: nil)]).isEmpty)
    }
    @Test func completedWithNilTimestampNotArchived() {
        #expect(ids([task("noStamp", completedAt: nil)]).isEmpty)
    }
    @Test func recentlyCompletedNotArchived() {
        #expect(ids([task("recent", completedAt: day(2026, 6, 14, 12))]).isEmpty)
    }
}
