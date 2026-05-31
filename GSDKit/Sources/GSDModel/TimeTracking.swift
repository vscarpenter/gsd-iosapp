import Foundation

public enum TimeTrackingError: Error, Equatable {
    case alreadyRunning
    case notRunning
}

/// Pure time-tracking operations over a task's `timeEntries` (product spec §6.9).
/// At most one running entry; `timeSpent` sums COMPLETED entries' seconds and
/// floors to whole minutes (sum-then-floor — documented scope call, PROBE-VERIFIED).
public enum TimeTracking {
    /// The single open (running) entry, if any.
    public static func runningEntry(_ entries: [TimeEntry]) -> TimeEntry? {
        entries.first { $0.endedAt == nil }
    }

    /// Begin a new entry. Rejects a second concurrent start.
    public static func start(_ entries: [TimeEntry], now: Date, newID: String) throws -> [TimeEntry] {
        guard runningEntry(entries) == nil else { throw TimeTrackingError.alreadyRunning }
        var result = entries
        result.append(TimeEntry(id: newID, startedAt: now))
        return result
    }

    /// Close the running entry. Optional notes attach to it. Rejects when none runs.
    public static func stop(_ entries: [TimeEntry], now: Date, notes: String? = nil) throws -> [TimeEntry] {
        guard let index = entries.firstIndex(where: { $0.endedAt == nil }) else {
            throw TimeTrackingError.notRunning
        }
        var result = entries
        result[index].endedAt = now
        if let notes { result[index].notes = notes }
        return result
    }

    /// Sum completed entries' durations in seconds, then floor to whole minutes.
    public static func timeSpentMinutes(_ entries: [TimeEntry]) -> Int {
        let totalSeconds = entries.reduce(0.0) { sum, entry in
            guard let endedAt = entry.endedAt else { return sum }
            return sum + endedAt.timeIntervalSince(entry.startedAt)
        }
        return Int(totalSeconds / 60.0)
    }

    /// Human-readable duration (product spec §6.9): `< 1m` / `Xm` / `Xh` / `Xh Ym`.
    public static func format(minutes: Int) -> String {
        if minutes < 1 { return String(localized: "< 1m") }
        if minutes < 60 { return String(localized: "\(minutes)m") }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0
            ? String(localized: "\(hours)h")
            : String(localized: "\(hours)h \(remainder)m")
    }
}
