import Foundation

/// Every dashboard metric (product spec §6.15), computed once by `AnalyticsEngine`.
/// Pure value type; the Dashboard is a render of this. Sendable so it crosses the
/// MainActor boundary from a background compute if ever needed.
public struct AnalyticsSummary: Equatable, Sendable {
    /// One day of the completion trend: created vs completed counts in `[startOfDay, +1day)`.
    public struct TrendPoint: Equatable, Sendable, Identifiable {
        public let date: Date          // startOfDay of the bucket
        public let created: Int
        public let completed: Int
        public var id: Date { date }
        public init(date: Date, created: Int, completed: Int) {
            self.date = date; self.created = created; self.completed = completed
        }
    }
    /// Per-quadrant counts. `total` = all tasks in the quadrant; `completed` ≤ `total`.
    public struct QuadrantStat: Equatable, Sendable, Identifiable {
        public let quadrant: Quadrant
        public let total: Int
        public let completed: Int
        public var id: Quadrant { quadrant }
        /// 0...1; 0 when the quadrant is empty.
        public var completionRate: Double { total == 0 ? 0 : Double(completed) / Double(total) }
        public init(quadrant: Quadrant, total: Int, completed: Int) {
            self.quadrant = quadrant; self.total = total; self.completed = completed
        }
    }
    /// Count of tasks carrying a given tag (active + completed).
    public struct TagStat: Equatable, Sendable, Identifiable {
        public let tag: String
        public let count: Int
        public var id: String { tag }
        public init(tag: String, count: Int) { self.tag = tag; self.count = count }
    }
    /// Total tracked minutes per quadrant (from `timeSpent`/`timeEntries`).
    public struct TimeByQuadrant: Equatable, Sendable, Identifiable {
        public let quadrant: Quadrant
        public let minutes: Int
        public var id: Quadrant { quadrant }
        public init(quadrant: Quadrant, minutes: Int) { self.quadrant = quadrant; self.minutes = minutes }
    }

    // Counts
    public let totalCount: Int
    public let activeCount: Int
    public let completedCount: Int
    /// Completed / total, 0...1; 0 when there are no tasks (div-by-zero guard).
    public let completionRate: Double

    // Streaks
    public let activeStreak: Int
    public let longestStreak: Int
    /// 7 entries, index 0 = 6-days-ago, index 6 = today; `true` iff that day had ≥1 completion.
    public let lastSevenDays: [Bool]

    // Distributions
    public let quadrantStats: [QuadrantStat]      // always 4, Q1→Q4 order
    public let topTags: [TagStat]                 // desc by count, capped (see engine)

    // Deadlines
    public let overdueCount: Int
    public let dueTodayCount: Int
    public let dueThisWeekCount: Int
    /// Active, dated, not-overdue tasks sorted by `dueDate` asc, capped (see engine).
    public let upcomingDeadlines: [Task]

    // Trend (length == requested trendDays)
    public let trend: [TrendPoint]

    // Time tracking
    public let totalTrackedMinutes: Int
    public let timeByQuadrant: [TimeByQuadrant]   // always 4, Q1→Q4 order

    public init(totalCount: Int, activeCount: Int, completedCount: Int, completionRate: Double,
                activeStreak: Int, longestStreak: Int, lastSevenDays: [Bool],
                quadrantStats: [QuadrantStat], topTags: [TagStat],
                overdueCount: Int, dueTodayCount: Int, dueThisWeekCount: Int, upcomingDeadlines: [Task],
                trend: [TrendPoint], totalTrackedMinutes: Int, timeByQuadrant: [TimeByQuadrant]) {
        self.totalCount = totalCount; self.activeCount = activeCount; self.completedCount = completedCount
        self.completionRate = completionRate; self.activeStreak = activeStreak
        self.longestStreak = longestStreak; self.lastSevenDays = lastSevenDays
        self.quadrantStats = quadrantStats; self.topTags = topTags
        self.overdueCount = overdueCount; self.dueTodayCount = dueTodayCount
        self.dueThisWeekCount = dueThisWeekCount; self.upcomingDeadlines = upcomingDeadlines
        self.trend = trend; self.totalTrackedMinutes = totalTrackedMinutes; self.timeByQuadrant = timeByQuadrant
    }

    /// The all-zero summary for an empty task set (drives the Dashboard empty state).
    public static func empty(trendDays: Int, now: Date, calendar: Calendar) -> AnalyticsSummary {
        AnalyticsEngine.compute(tasks: [], now: now, calendar: calendar, trendDays: trendDays)
    }
}
