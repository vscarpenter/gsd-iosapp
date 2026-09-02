import Testing
import Foundation
@testable import GSDModel

struct DeadlineStatusTests {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Chicago")!
        return c
    }()

    /// June 2026, at the given hour in the test calendar's zone.
    private func june(_ day: Int, hour: Int) -> Date {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 6; comps.day = day; comps.hour = hour
        return calendar.date(from: comps)!
    }

    @Test func dueYesterdayIsOverdue() {
        #expect(DeadlineStatus.of(dueDate: june(2, hour: 12), now: june(3, hour: 9), calendar: calendar) == .overdue)
    }

    /// Agrees with `AnalyticsEngine.overdueCount` and the Overdue Backlog smart view:
    /// only dates before the START of today are overdue, so a due-at-midnight task
    /// seen at 9am is today's, not overdue.
    @Test func dueEarlierTodayIsTodayNotOverdue() {
        #expect(DeadlineStatus.of(dueDate: june(3, hour: 0), now: june(3, hour: 9), calendar: calendar) == .today)
    }

    @Test func dueLaterTodayIsToday() {
        #expect(DeadlineStatus.of(dueDate: june(3, hour: 23), now: june(3, hour: 9), calendar: calendar) == .today)
    }

    @Test func dueTomorrowIsUpcoming() {
        #expect(DeadlineStatus.of(dueDate: june(4, hour: 0), now: june(3, hour: 23), calendar: calendar) == .upcoming)
    }
}
