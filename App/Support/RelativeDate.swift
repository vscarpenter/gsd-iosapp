import Foundation

/// Relative due-date phrasing for cards (product spec §6.10): "Due today",
/// overdue, or a relative future string. `reference` (now) is injected so the
/// caller controls the clock; the calendar defaults to `.current`.
enum RelativeDate {
    enum DueState { case overdue, today, upcoming }

    static func state(for dueDate: Date, reference: Date = .now, calendar: Calendar = .current) -> DueState {
        if calendar.isDate(dueDate, inSameDayAs: reference) { return .today }
        return dueDate < calendar.startOfDay(for: reference) ? .overdue : .upcoming
    }

    /// DAY-granular phrasing for DUE DATES (product spec §6.10): "Due today",
    /// "in 3 days", "2 days ago". Both dates are floored to start-of-day.
    static func dueString(for dueDate: Date, reference: Date = .now, calendar: Calendar = .current) -> String {
        switch state(for: dueDate, reference: reference, calendar: calendar) {
        case .today:
            return String(localized: "Due today")
        case .overdue, .upcoming:
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            return formatter.localizedString(for: calendar.startOfDay(for: dueDate),
                                             relativeTo: calendar.startOfDay(for: reference))
        }
    }

    /// TIME-granular remaining phrasing for SNOOZE (product spec §6.7): "in 1 hr",
    /// "in 45 min". Must NOT floor to start-of-day — the four short presets
    /// (15m/30m/1h/3h) land on the same calendar day, and snooze must show remaining
    /// time, not "Due today" (acceptance criterion A10).
    static func remainingString(until date: Date, reference: Date = .now) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: reference)
    }
}
