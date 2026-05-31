import Foundation

/// The four quick-set due-date presets (product spec §6.10).
public enum DueDatePreset: String, CaseIterable, Sendable {
    case none, today, thisWeek, nextWeek

    public var label: String {
        switch self {
        case .none:     String(localized: "None")
        case .today:    String(localized: "Today")
        case .thisWeek: String(localized: "This week")
        case .nextWeek: String(localized: "Next week")
        }
    }
}

/// Resolves a preset to a concrete due date (product spec §6.10), all in the
/// injected calendar's time zone, at START OF DAY. Weekday math uses explicit
/// `.weekday` component arithmetic (Sun=1…Sat=7) so it is INDEPENDENT of the
/// calendar's `firstWeekday`/locale. PROBE-VERIFIED — do NOT refactor to
/// `dateInterval(of: .weekOfYear,…)`, which IS locale-dependent.
public enum DueDatePresets {
    private static let friday = 6   // gregorian weekday number
    private static let monday = 2

    public static func resolve(_ preset: DueDatePreset, today: Date, calendar: Calendar) -> Date? {
        let start = calendar.startOfDay(for: today)
        switch preset {
        case .none:
            return nil
        case .today:
            return start
        case .thisWeek:
            return thisWeekFriday(from: start, calendar: calendar)
        case .nextWeek:
            return nextWeekMonday(from: start, calendar: calendar)
        }
    }

    /// Friday of the current week; if today is Sat/Sun, the NEXT Friday.
    private static func thisWeekFriday(from start: Date, calendar: Calendar) -> Date {
        let weekday = calendar.component(.weekday, from: start) // 1=Sun…7=Sat
        let delta: Int
        if weekday == 7 || weekday == 1 { // Saturday or Sunday → next Friday
            let raw = (friday - weekday + 7) % 7
            delta = raw == 0 ? 7 : raw
        } else { // Mon…Fri → this week's Friday (today if already Friday)
            delta = friday - weekday
        }
        return calendar.date(byAdding: .day, value: delta, to: start)!
    }

    /// Monday of next week, strictly after today (today-is-Monday → +7).
    private static func nextWeekMonday(from start: Date, calendar: Calendar) -> Date {
        let weekday = calendar.component(.weekday, from: start)
        var delta = (monday - weekday + 7) % 7
        if delta == 0 { delta = 7 }
        return calendar.date(byAdding: .day, value: delta, to: start)!
    }
}
