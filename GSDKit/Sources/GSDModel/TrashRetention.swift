import Foundation

/// Pure trash-retention rules. A trashed task is recoverable for `days` days, then the
/// sweep purges it — matching the web client's 30-day window (its ADR 0015) so the same
/// deletion behaves the same on both.
///
/// The cutoff anchors to the START OF TODAY, not the current instant, so it is stable
/// across the day rather than sliding forward every second the app is open. This is the
/// same convention `AutoArchive` and `TaskFilter`'s `overdue` use — PROBE-VERIFIED
/// boundary: a row stamped exactly ON the cutoff is KEPT (strictly-before expires).
public enum TrashRetention {
    public static let days = 30

    /// Rows stamped strictly before this instant have expired.
    public static func cutoff(now: Date, calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: now))!
    }

    public static func isExpired(deletedAt: Date, now: Date, calendar: Calendar) -> Bool {
        deletedAt < cutoff(now: now, calendar: calendar)
    }

    /// Whole days left before this row is purged, floored at zero. Drives the "29 days
    /// left" copy in the trash list, so it counts down from `days` on the day of deletion.
    public static func daysRemaining(deletedAt: Date, now: Date, calendar: Calendar) -> Int {
        let elapsed = calendar.startOfDay(for: now).timeIntervalSince(deletedAt) / 86_400
        return max(0, days - Int(elapsed.rounded(.up)))
    }
}
