import Foundation

/// Pure filtering over a task set (product spec §5.9). Caller injects `now`/`calendar`
/// so date predicates are deterministic. `readyToWork` resolves against the FULL input
/// set (a blocker excluded by another criterion must still block). PROBE-VERIFIED dates.
public enum TaskFilter {
    public static func apply(_ c: FilterCriteria, to tasks: [Task], now: Date, calendar: Calendar) -> [Task] {
        let startToday = calendar.startOfDay(for: now)
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: startToday)!   // [startToday, +7)
        let recentCutoff = calendar.date(byAdding: .day, value: -7, to: now)!    // rolling from now
        let graph = DependencyGraph(tasks: tasks)
        let query = c.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        return tasks.filter { task in
            switch c.status {
            case .all: break
            case .active: if task.completed { return false }
            case .completed: if !task.completed { return false }
            }
            if !c.quadrants.isEmpty, !c.quadrants.contains(task.quadrant) { return false }
            if !c.tags.allSatisfy({ task.tags.contains($0) }) { return false }
            if !c.recurrence.isEmpty, !c.recurrence.contains(task.recurrence) { return false }
            if let range = c.dueDateRange {
                guard let due = task.dueDate else { return false }
                if let s = range.start, due < s { return false }
                if let e = range.end, due > e { return false }
            }
            if c.overdue { guard !task.completed, let due = task.dueDate, due < startToday else { return false } }
            if c.dueToday { guard !task.completed, let due = task.dueDate, calendar.isDate(due, inSameDayAs: now) else { return false } }
            if c.dueThisWeek { guard !task.completed, let due = task.dueDate, due >= startToday, due < weekEnd else { return false } }
            if c.noDueDate, task.dueDate != nil { return false }
            if c.recentlyAdded { guard task.createdAt >= recentCutoff, task.createdAt <= now else { return false } }
            if c.recentlyCompleted { guard task.completed, let at = task.completedAt, at >= recentCutoff, at <= now else { return false } }
            if c.readyToWork { guard !task.completed, graph.uncompletedBlockers(of: task.id).isEmpty else { return false } }
            if !query.isEmpty {
                let hay = [task.title, task.description] + task.tags + task.subtasks.map(\.title)
                if !hay.contains(where: { $0.lowercased().contains(query) }) { return false }
            }
            return true
        }
    }
}
