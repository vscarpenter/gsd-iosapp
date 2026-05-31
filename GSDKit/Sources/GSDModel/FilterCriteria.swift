import Foundation

/// Predicate bundle powering smart views, filters, and search (product spec §5.9).
/// All present criteria are ANDed. A `Bool` flag of `false` means "don't constrain on
/// this" — only `true` adds a predicate. Empty arrays/`.all`/empty query = no constraint.
public struct FilterCriteria: Equatable, Sendable {
    public enum Status: Sendable, Equatable { case all, active, completed }
    public struct DateRange: Equatable, Sendable {
        public var start: Date?
        public var end: Date?
        public init(start: Date? = nil, end: Date? = nil) { self.start = start; self.end = end }
    }

    public var quadrants: [Quadrant]
    public var status: Status
    public var tags: [String]
    public var dueDateRange: DateRange?
    public var overdue: Bool
    public var dueToday: Bool
    public var dueThisWeek: Bool
    public var noDueDate: Bool
    public var recurrence: [RecurrenceType]
    public var recentlyAdded: Bool
    public var recentlyCompleted: Bool
    public var readyToWork: Bool
    public var searchQuery: String

    public init(quadrants: [Quadrant] = [], status: Status = .all, tags: [String] = [],
                dueDateRange: DateRange? = nil, overdue: Bool = false, dueToday: Bool = false,
                dueThisWeek: Bool = false, noDueDate: Bool = false, recurrence: [RecurrenceType] = [],
                recentlyAdded: Bool = false, recentlyCompleted: Bool = false, readyToWork: Bool = false,
                searchQuery: String = "") {
        self.quadrants = quadrants; self.status = status; self.tags = tags
        self.dueDateRange = dueDateRange; self.overdue = overdue; self.dueToday = dueToday
        self.dueThisWeek = dueThisWeek; self.noDueDate = noDueDate; self.recurrence = recurrence
        self.recentlyAdded = recentlyAdded; self.recentlyCompleted = recentlyCompleted
        self.readyToWork = readyToWork; self.searchQuery = searchQuery
    }
}
