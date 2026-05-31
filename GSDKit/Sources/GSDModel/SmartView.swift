import Foundation

/// A named, icon'd filter (product spec §5.6). In Phase 3a the 9 built-ins are in-code
/// constants (no `smartViews` table yet — custom views + persistence arrive in 3b).
public struct SmartView: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let icon: String          // SF Symbol name
    public let criteria: FilterCriteria
    public let isBuiltIn: Bool

    public init(id: String, name: String, icon: String, criteria: FilterCriteria, isBuiltIn: Bool = true) {
        self.id = id; self.name = name; self.icon = icon; self.criteria = criteria; self.isBuiltIn = isBuiltIn
    }
}

/// The nine read-only built-in views (product spec §6.13), stable IDs, canonical order.
public enum BuiltInSmartViews {
    public static let all: [SmartView] = [
        SmartView(id: "today-focus", name: String(localized: "Today's Focus"), icon: "target",
                  criteria: FilterCriteria(quadrants: [.urgentImportant], status: .active)),
        SmartView(id: "this-week", name: String(localized: "This Week"), icon: "calendar",
                  criteria: FilterCriteria(status: .active, dueThisWeek: true)),
        SmartView(id: "overdue", name: String(localized: "Overdue Backlog"), icon: "exclamationmark.triangle",
                  criteria: FilterCriteria(status: .active, overdue: true)),
        SmartView(id: "no-deadline", name: String(localized: "No Deadline"), icon: "calendar.badge.minus",
                  criteria: FilterCriteria(status: .active, noDueDate: true)),
        SmartView(id: "recently-added", name: String(localized: "Recently Added"), icon: "sparkles",
                  criteria: FilterCriteria(status: .active, recentlyAdded: true)),
        SmartView(id: "weeks-wins", name: String(localized: "This Week's Wins"), icon: "trophy",
                  criteria: FilterCriteria(status: .completed, recentlyCompleted: true)),
        SmartView(id: "all-completed", name: String(localized: "All Completed"), icon: "checkmark.circle",
                  criteria: FilterCriteria(status: .completed)),
        SmartView(id: "recurring", name: String(localized: "Recurring Tasks"), icon: "repeat",
                  criteria: FilterCriteria(status: .active, recurrence: [.daily, .weekly, .monthly])),
        SmartView(id: "ready-to-work", name: String(localized: "Ready to Work"), icon: "bolt",
                  criteria: FilterCriteria(status: .active, readyToWork: true)),
    ]
}
