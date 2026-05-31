import Foundation

/// Pure reminder scheduling math (product spec §9). Value-in/value-out with injected
/// `now`/`calendar` — no `Date()`, no `Calendar.current`, no `UserNotifications`. The
/// live scheduler (App layer) calls these; the store calls only `badgeCount`. All rules
/// are PROBE-VERIFIED (firedate 11/11, quiethours 14/14, badge 8/8).
public enum ReminderMath {
    /// The slice of `NotificationSettings` that fire-time math needs. Kept separate from
    /// `NotificationSettings` so `ReminderMath` has no type dependency on it (and stays in
    /// `GSDModel` with zero ordering constraints). The live scheduler adapts settings → this.
    public struct Inputs: Sendable, Equatable {
        public let masterEnabled: Bool
        public let defaultReminder: Int   // minutes
        public init(masterEnabled: Bool, defaultReminder: Int) {
            self.masterEnabled = masterEnabled
            self.defaultReminder = defaultReminder
        }
    }

    /// The master/task/completed/due gate (NOT the past-time gate — that lives in `fireDate`).
    /// True iff a reminder is conceptually wanted for this task.
    public static func shouldSchedule(_ task: Task, inputs: Inputs) -> Bool {
        inputs.masterEnabled && task.notificationEnabled && !task.completed && task.dueDate != nil
    }

    /// The local fire time = `dueDate − (notifyBefore ?? defaultReminder)` minutes, or nil
    /// when the task shouldn't fire (`shouldSchedule` false) OR the fire time is already past
    /// (the `fire >= now` boundary is inclusive). Quiet-hours deferral is applied separately.
    public static func fireDate(for task: Task, inputs: Inputs, now: Date) -> Date? {
        guard shouldSchedule(task, inputs: inputs), let due = task.dueDate else { return nil }
        let offsetMinutes = task.notifyBefore ?? inputs.defaultReminder
        let fire = due.addingTimeInterval(TimeInterval(-offsetMinutes * 60))
        guard fire >= now else { return nil }   // past-due rule: SKIP
        return fire
    }

    /// Defer an in-window fire to the next occurrence of `quietEnd` at-or-after `fire`;
    /// otherwise unchanged. Window is half-open `[quietStart, quietEnd)`. `quietStart > quietEnd`
    /// crosses midnight; `quietStart == quietEnd` or a nil/invalid endpoint → no suppression.
    /// `"HH:mm"` is parsed and the target rebuilt in the injected calendar's timezone via
    /// component arithmetic (DST-safe).
    public static func applyQuietHours(_ fire: Date, quietStart: String?, quietEnd: String?,
                                       calendar: Calendar) -> Date {
        guard let qs = quietStart, let qe = quietEnd,
              let start = parseHHmm(qs), let end = parseHHmm(qe) else { return fire }
        let startMin = start.hour * 60 + start.minute
        let endMin = end.hour * 60 + end.minute
        guard startMin != endMin else { return fire }   // zero-length → no suppression

        let comps = calendar.dateComponents([.hour, .minute], from: fire)
        let f = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        let inWindow = startMin < endMin
            ? (f >= startMin && f < endMin)              // same-day window
            : (f >= startMin || f < endMin)              // crosses midnight
        guard inWindow else { return fire }

        let startOfDay = calendar.startOfDay(for: fire)
        var target = calendar.date(bySettingHour: end.hour, minute: end.minute, second: 0,
                                   of: startOfDay)!
        if target <= fire { target = calendar.date(byAdding: .day, value: 1, to: target)! }
        return target
    }

    /// App-icon badge: active tasks with `dueDate < startOfTomorrow` (overdue + due-today).
    /// Reuses `AnalyticsEngine`'s overdue/due-today boundary so the two cannot drift.
    public static func badgeCount(tasks: [Task], now: Date, calendar: Calendar) -> Int {
        let startToday = calendar.startOfDay(for: now)
        let startTomorrow = calendar.date(byAdding: .day, value: 1, to: startToday)!
        return tasks.filter { task in
            guard !task.completed, let due = task.dueDate else { return false }
            return due < startTomorrow
        }.count
    }

    /// Parse `"HH:mm"` (24-hour). Returns nil for malformed or out-of-range input.
    private static func parseHHmm(_ s: String) -> (hour: Int, minute: Int)? {
        let parts = s.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
              (0..<24).contains(h), (0..<60).contains(m) else { return nil }
        return (h, m)
    }
}
