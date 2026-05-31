import Foundation

/// Recurrence date math + instance spawning (product spec §6.5). Pure: the
/// caller injects the `Calendar` (so month-end clamping and time zone are
/// deterministic) and "now" (so spawn timestamps are testable).
public enum RecurrenceEngine {
    /// Advance a due date by one recurrence period. `.none` (no recurrence) and a
    /// `.daily`/`.weekly`/`.monthly` with no due date both return nil — there is
    /// nothing to advance. Monthly uses `Calendar` month arithmetic, which clamps
    /// to the last valid day (Jan 31 + 1mo → Feb 28/29). PROBE-VERIFIED.
    public static func advance(_ dueDate: Date?, by recurrence: RecurrenceType, calendar: Calendar) -> Date? {
        guard let dueDate else { return nil }
        switch recurrence {
        case .none:    return nil
        case .daily:   return calendar.date(byAdding: .day, value: 1, to: dueDate)
        case .weekly:  return calendar.date(byAdding: .day, value: 7, to: dueDate)
        case .monthly: return calendar.date(byAdding: .month, value: 1, to: dueDate)
        }
    }
}
