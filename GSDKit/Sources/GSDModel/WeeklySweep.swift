import Foundation

/// Weekly sweep (decision D-14; spec `gsd-taskmanager/tasks/spec-weekly-sweep.md`): the pure rules
/// for a short pass through what has gone quiet. Nothing here writes. Pinned by the shared 74-case
/// corpus (`SweepCorpusTests`); the web repo is the authority.
public enum WeeklySweep {
    public static let staleDays = 14
    public static let savedDays = 30
    public static let entryDays = 7

    public enum Reason: String, Sendable, Equatable {
        case overdue, escalating, stale, saved
        case undatedSchedule = "undated-schedule"
    }

    public struct Card: Sendable, Equatable {
        public let id: String
        public let reason: Reason
    }

    // MARK: - Cards (spec 3)

    /// One card per task, from the first group it qualifies for, in group order. The input is
    /// active-store rows; completed rows are ignored. Every age counts local calendar days in
    /// `timeZone`, never elapsed time. `windowDays` is nil when escalation is Off.
    public static func cards(_ tasks: [Task], now: Date, windowDays: Int?, timeZone: TimeZone) -> [Card] {
        var overdue: [Task] = [], escalating: [Task] = [], stale: [Task] = []
        var saved: [Task] = [], undated: [Task] = []
        for task in tasks where !task.completed {
            let result = Escalation.evaluate(task, now: now, windowDays: windowDays, timeZone: timeZone)
            if task.savedAt != nil {
                if let age = daysAgo(task.savedAt, now: now, timeZone: timeZone), age >= savedDays { saved.append(task) }
            } else if let days = result.daysUntilDue, days < 0 {
                overdue.append(task)
            } else if result.escalating, result.reason == .dueSoon {
                escalating.append(task)
            } else if let age = daysAgo(task.updatedAt, now: now, timeZone: timeZone), age >= staleDays {
                stale.append(task)
            } else if task.important, !task.urgent, task.dueDate == nil {
                undated.append(task)
            }
        }
        let byDue: (Task, Task) -> Bool = { a, b in
            if a.dueDate != b.dueDate { return (a.dueDate ?? .distantFuture) < (b.dueDate ?? .distantFuture) }
            if a.important != b.important { return a.important }
            return a.id < b.id
        }
        let isQ4: (Task) -> Bool = { !$0.urgent && !$0.important }
        let byStale: (Task, Task) -> Bool = { a, b in
            if isQ4(a) != isQ4(b) { return isQ4(a) }
            if a.updatedAt != b.updatedAt { return a.updatedAt < b.updatedAt }
            return a.id < b.id
        }
        let bySaved: (Task, Task) -> Bool = { a, b in
            if a.savedAt != b.savedAt { return (a.savedAt ?? .distantFuture) < (b.savedAt ?? .distantFuture) }
            return a.id < b.id
        }
        let byCreated: (Task, Task) -> Bool = { a, b in
            a.createdAt != b.createdAt ? a.createdAt < b.createdAt : a.id < b.id
        }
        func make(_ list: [Task], _ reason: Reason, _ order: (Task, Task) -> Bool) -> [Card] {
            list.sorted(by: order).map { Card(id: $0.id, reason: reason) }
        }
        return make(overdue, .overdue, byDue) + make(escalating, .escalating, byDue)
            + make(stale, .stale, byStale) + make(saved, .saved, bySaved)
            + make(undated, .undatedSchedule, byCreated)
    }

    /// Local calendar days from `date` to `now`; negative for a future stamp, so it never qualifies.
    private static func daysAgo(_ date: Date?, now: Date, timeZone: TimeZone) -> Int? {
        guard let date else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                       to: calendar.startOfDay(for: now)).day
    }

    // MARK: - Entry (spec 6)

    /// True with at least one card, when the device has never swept or last swept seven or more
    /// local days ago. A future `lastSweptAt` counts as swept recently.
    public static func entryShown(lastSweptAt: Date?, cardCount: Int, now: Date, timeZone: TimeZone) -> Bool {
        guard cardCount > 0 else { return false }
        guard let lastSweptAt else { return true }
        return (daysAgo(lastSweptAt, now: now, timeZone: timeZone) ?? 0) >= entryDays
    }

    // MARK: - Reminder (spec 6)

    /// The per-device reminder: ISO weekday (1 is Monday, 7 is Sunday) and local time.
    public struct Reminder: Sendable, Equatable {
        public var enabled: Bool
        public var weekday: Int
        public var hour: Int
        public var minute: Int

        public static let off = Reminder(enabled: false, weekday: 7, hour: 9, minute: 0)

        /// The weekday in `Calendar`'s numbering (1 is Sunday), for a calendar trigger.
        public var calendarWeekday: Int { weekday % 7 + 1 }

        public init(enabled: Bool, weekday: Int, hour: Int, minute: Int) {
            self.enabled = enabled
            self.weekday = weekday
            self.hour = hour
            self.minute = minute
        }
    }

    /// The next occurrence of the weekday and local time strictly after `now`, or nil when off.
    /// It keeps its wall-clock time across a clock change. A time inside a gap shifts forward by
    /// the gap, and a time inside an overlap takes the first occurrence.
    public static func nextReminder(_ reminder: Reminder, now: Date, timeZone: TimeZone) -> Date? {
        guard reminder.enabled else { return nil }
        var local = Calendar(identifier: .gregorian)
        local.timeZone = timeZone
        let today = local.dateComponents([.year, .month, .day], from: now)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt
        guard let todayCivil = utc.date(from: today) else { return nil }
        for offset in 0...7 {
            guard let civil = utc.date(byAdding: .day, value: offset, to: todayCivil),
                  isoWeekday(civil, calendar: utc) == reminder.weekday
            else { continue }
            let wall = civil.timeIntervalSince1970 + Double(reminder.hour * 3600 + reminder.minute * 60)
            let fire = instant(wallClock: wall, timeZone: timeZone)
            if fire > now { return fire }
        }
        return nil
    }

    private static func isoWeekday(_ date: Date, calendar: Calendar) -> Int {
        (calendar.component(.weekday, from: date) + 5) % 7 + 1   // Calendar: 1 is Sunday
    }

    /// Turns a wall-clock time (seconds as if the zone were UTC) into an instant. With two valid
    /// readings (an overlap) it takes the earlier. With none (a gap) it applies the offset from
    /// before the change, which lands the time later by the length of the gap.
    private static func instant(wallClock wall: TimeInterval, timeZone: TimeZone) -> Date {
        let before = timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: wall - 86_400))
        let after = timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: wall + 86_400))
        let candidates = Set([before, after]).map { Date(timeIntervalSince1970: wall - Double($0)) }
            .filter { timeZone.secondsFromGMT(for: $0) == Int(wall - $0.timeIntervalSince1970) }
        return candidates.min() ?? Date(timeIntervalSince1970: wall - Double(before))
    }
}
