import Foundation

/// A due date's optional time of day (decision D-1, shared with web and Android). A due date at
/// local midnight is "all day"; any other time, down to the millisecond, is a time of day. The
/// stored `Date` carries both, so nothing extra is persisted or synced.
///
/// Every date is built from `DateComponents`, never `Calendar.date(bySettingHour:)`: a local time
/// inside a daylight-saving gap shifts forward by the gap's length (02:30 becomes 03:30), where
/// `bySettingHour` lands on the end of the gap (03:00) and disagrees with the shared corpus.
public enum DueTime {
    /// The local hour and minute of a due date, or nil when it is all day.
    public static func time(of due: Date, calendar: Calendar) -> (hour: Int, minute: Int)? {
        let c = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: due)
        let milliseconds = Int(((Double(c.nanosecond ?? 0)) / 1_000_000).rounded())
        let atMidnight = (c.hour ?? 0) == 0 && (c.minute ?? 0) == 0 && (c.second ?? 0) == 0 && milliseconds == 0
        return atMidnight ? nil : (c.hour ?? 0, c.minute ?? 0)
    }

    public static func isAllDay(_ due: Date, calendar: Calendar) -> Bool {
        time(of: due, calendar: calendar) == nil
    }

    /// Moves the due date to the local day `day` (year, month, day), keeping the time already set,
    /// down to the millisecond. No due date means all day.
    public static func onDate(_ due: Date?, to day: DateComponents, calendar: Calendar) -> Date {
        var target = DateComponents(year: day.year, month: day.month, day: day.day)
        if let due, !isAllDay(due, calendar: calendar) {
            let t = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: due)
            target.hour = t.hour
            target.minute = t.minute
            target.second = t.second
            target.nanosecond = t.nanosecond
        }
        return calendar.date(from: target)!
    }

    /// Sets the time on the same local day, dropping seconds. Nil makes the due date all day again.
    public static func atTime(_ due: Date, _ time: (hour: Int, minute: Int)?, calendar: Calendar) -> Date {
        var target = calendar.dateComponents([.year, .month, .day], from: due)
        target.hour = time?.hour ?? 0
        target.minute = time?.minute ?? 0
        return calendar.date(from: target)!
    }
}
