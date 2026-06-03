import Foundation
import GSDModel

/// Pure projection of the app's task set onto the Today's Focus snapshot (spec §5).
/// Reuses the SAME `today-focus` criteria + `TaskFilter` the in-app smart view uses.
public enum WidgetSnapshotBuilder {
    public static let todaysFocusViewID = "today-focus"

    public static func todaysFocus(
        from tasks: [Task], now: Date, calendar: Calendar = .current, limit: Int = 8
    ) -> WidgetSnapshot {
        let criteria = BuiltInSmartViews.all
            .first { $0.id == todaysFocusViewID }!.criteria   // static built-in: always present
        let matched = TaskFilter.apply(criteria, to: tasks, now: now, calendar: calendar)
        let rows = matched.prefix(limit).map {
            WidgetTask(id: $0.id, title: $0.title, dueDate: $0.dueDate)
        }
        return WidgetSnapshot(generatedAt: now, tasks: Array(rows), totalCount: matched.count)
    }
}
