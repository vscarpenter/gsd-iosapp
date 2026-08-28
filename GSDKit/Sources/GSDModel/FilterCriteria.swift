import Foundation

/// Predicate bundle powering smart views, filters, and search (product spec §5.9).
/// All present criteria are ANDed. A `Bool` flag of `false` means "don't constrain on
/// this" — only `true` adds a predicate. Empty arrays/`.all`/empty query = no constraint.
public struct FilterCriteria: Equatable, Sendable, Codable {
    public enum Status: String, Sendable, Equatable, Codable, CaseIterable { case all, active, completed }
    public struct DateRange: Equatable, Sendable, Codable {
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

    private enum CodingKeys: String, CodingKey {
        case quadrants, status, tags, dueDateRange, overdue, dueToday, dueThisWeek
        case noDueDate, recurrence, recentlyAdded, recentlyCompleted, readyToWork, searchQuery
    }

    /// Lenient decode: default every absent field exactly as the member init does.
    ///
    /// REQUIRED for cross-client backups. The web writes only the criteria a view actually
    /// constrains on — every other key is optional in its schema and simply omitted — so the
    /// synthesized decoder, which demands all thirteen, could not read a single real web
    /// smart view. It threw on the first missing key and failed the whole import.
    ///
    /// A default of `false`/`[]`/`""` means "don't constrain on this", which is precisely
    /// what an absent key means on the web too, so the two agree on meaning and not just
    /// on shape. Encoding stays synthesized (all keys written) — harmless, since the web's
    /// schema accepts every one of them.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        quadrants = try c.decodeIfPresent([Quadrant].self, forKey: .quadrants) ?? []
        status = try c.decodeIfPresent(Status.self, forKey: .status) ?? .all
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        dueDateRange = try c.decodeIfPresent(DateRange.self, forKey: .dueDateRange)
        overdue = try c.decodeIfPresent(Bool.self, forKey: .overdue) ?? false
        dueToday = try c.decodeIfPresent(Bool.self, forKey: .dueToday) ?? false
        dueThisWeek = try c.decodeIfPresent(Bool.self, forKey: .dueThisWeek) ?? false
        noDueDate = try c.decodeIfPresent(Bool.self, forKey: .noDueDate) ?? false
        recurrence = try c.decodeIfPresent([RecurrenceType].self, forKey: .recurrence) ?? []
        recentlyAdded = try c.decodeIfPresent(Bool.self, forKey: .recentlyAdded) ?? false
        recentlyCompleted = try c.decodeIfPresent(Bool.self, forKey: .recentlyCompleted) ?? false
        readyToWork = try c.decodeIfPresent(Bool.self, forKey: .readyToWork) ?? false
        searchQuery = try c.decodeIfPresent(String.self, forKey: .searchQuery) ?? ""
    }
}
