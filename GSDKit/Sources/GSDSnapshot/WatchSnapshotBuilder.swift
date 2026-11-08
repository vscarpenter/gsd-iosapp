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

        // Rule 3: a pick dated yesterday or later, so time-zone edges and the midnight rule still
        // have the data. Dates compare as text (`TopThree`), the same way the rules do.
        let yesterday = TopThree.localDate(calendar.date(byAdding: .day, value: -1, to: startToday)!,
                                           timeZone: calendar.timeZone)
        func isRecentPick(_ task: Task) -> Bool { task.focusDate.map { $0 >= yesterday } ?? false }

        let carried = active.filter { task in
            if isRecentPick(task) { return true }
            if task.urgent && task.important { return true }
            guard !task.urgent, let due = task.dueDate else { return false }
            return due < reachEnd          // overdue, or within 7 calendar days ahead
        }
        // Over the cap, picks stay first, then due date, then `createdAt`.
        let ordered = carried.sorted { a, b in
            let (pickA, pickB) = (isRecentPick(a), isRecentPick(b))
            return pickA != pickB ? pickA : dueThenCreated(a, b)
        }.prefix(WatchSnapshot.taskCap)

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
