import Foundation
import GSDModel

/// Pure projection of the iPhone's active tasks onto the watch snapshot (spec 6.2).
public enum WatchSnapshotBuilder {
    /// The longest escalation window (one week), so a later change to the setting still has rows.
    static let reachDays = 7

    public static func build(
        from tasks: [Task], now: Date, calendar: Calendar = .current,
        escalationWindowDays: Int?, appliedCommandIDs: [String]
    ) -> WatchSnapshot {
        let active = tasks.filter { !$0.completed && !$0.isSaved }
        let startToday = calendar.startOfDay(for: now)
        let reachEnd = calendar.date(byAdding: .day, value: reachDays + 1, to: startToday)!

        let carried = active.filter { task in
            if task.urgent && task.important { return true }
            guard !task.urgent, let due = task.dueDate else { return false }
            return due < reachEnd          // overdue, or within 7 calendar days ahead
        }
        let ordered = carried.sorted(by: dueThenCreated).prefix(WatchSnapshot.taskCap)

        return WatchSnapshot(
            generatedAt: now,
            escalationWindowDays: escalationWindowDays,
            tasks: ordered.map(WatchTask.init),
            doFirstTotal: WidgetSnapshotBuilder.todaysFocus(from: active, now: now, calendar: calendar).totalCount,
            appliedCommandIDs: Array(appliedCommandIDs.suffix(WatchSnapshot.appliedCommandCap)))
    }

    /// Due date ascending (undated last), then `createdAt`, then id so the cut is deterministic.
    static func dueThenCreated(_ a: Task, _ b: Task) -> Bool {
        switch (a.dueDate, b.dueDate) {
        case let (x?, y?) where x != y: return x < y
        case (_?, nil): return true
        case (nil, _?): return false
        default: break
        }
        if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
        return a.id < b.id
    }
}
