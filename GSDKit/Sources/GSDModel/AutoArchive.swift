import Foundation

/// Pure auto-archive selection (design-spec scope call). A completed task is archived
/// when its `completedAt` is strictly older than `afterDays` days before the START OF
/// TODAY — i.e. `completedAt < startOfDay(now) − afterDays`. The anchor is `startOfDay`
/// (consistent with `TaskFilter`'s `overdue`), so the cutoff is stable across the day.
/// Incomplete tasks and completed-but-unstamped tasks never archive. The enabled toggle
/// is NOT consulted here — gating lives in the store's sweep. PROBE-VERIFIED boundary.
public enum AutoArchive {
    public static func tasksToArchive(_ tasks: [Task], afterDays days: Int,
                                      now: Date, calendar: Calendar) -> [Task] {
        let cutoff = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: now))!
        return tasks.filter { task in
            guard task.completed, let completedAt = task.completedAt else { return false }
            return completedAt < cutoff
        }
    }
}
