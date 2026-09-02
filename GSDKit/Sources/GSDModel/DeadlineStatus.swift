import Foundation

/// Where a due date sits relative to today, for the dashboard's deadline badges.
/// Day-based in the injected calendar, so it agrees with `AnalyticsEngine.overdueCount`
/// and the Overdue Backlog smart view (`TaskFilter`): only dates before the START of
/// today are overdue. A task due today is `.today`, never overdue.
public enum DeadlineStatus: Sendable, Equatable {
    case overdue, today, upcoming

    public static func of(dueDate: Date, now: Date, calendar: Calendar) -> DeadlineStatus {
        if dueDate < calendar.startOfDay(for: now) { return .overdue }
        if calendar.isDate(dueDate, inSameDayAs: now) { return .today }
        return .upcoming
    }
}
