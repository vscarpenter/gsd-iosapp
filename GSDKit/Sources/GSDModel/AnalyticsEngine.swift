import Foundation

/// Computes every dashboard metric (product spec §6.15) from a task set, with injected
/// `now`/`calendar` so all date math is deterministic. Pure: value-in/value-out, no
/// side effects, no `Date()`/`Calendar.current`. Streak + trend logic is PROBE-VERIFIED.
public enum AnalyticsEngine {
    /// Cap on `topTags` / `upcomingDeadlines` so the dashboard renders a bounded list.
    public static let topTagsLimit = 8
    public static let upcomingLimit = 5

    public static func compute(tasks: [Task], now: Date, calendar: Calendar, trendDays: Int) -> AnalyticsSummary {
        let startToday = calendar.startOfDay(for: now)
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: startToday)!   // [startToday, +7)

        // Counts
        let total = tasks.count
        let completed = tasks.filter(\.completed)
        let completedCount = completed.count
        let activeCount = total - completedCount
        let completionRate = total == 0 ? 0 : Double(completedCount) / Double(total)

        // Period completion counts over completed tasks with a non-nil `completedAt`.
        // Today = same calendar day as `now`; week/month use the device-week boundaries
        // (`dateInterval` is `firstWeekday`-dependent and end-inclusive, but the boundary
        // instants never coincide with a completion timestamp in practice).
        let weekInterval = calendar.dateInterval(of: .weekOfYear, for: now)
        let monthInterval = calendar.dateInterval(of: .month, for: now)
        let completedDates = completed.compactMap(\.completedAt)
        let completedToday = completedDates.filter { calendar.isDate($0, inSameDayAs: now) }.count
        let completedThisWeek = completedDates.filter { weekInterval?.contains($0) ?? false }.count
        let completedThisMonth = completedDates.filter { monthInterval?.contains($0) ?? false }.count

        // Streaks (probe-pinned). A completion day = startOfDay(completedAt).
        let completionDays = Set(completed.compactMap { $0.completedAt }.map { calendar.startOfDay(for: $0) })
        let activeStreak = Self.activeStreak(startToday: startToday, days: completionDays, calendar: calendar)
        let longestStreak = Self.longestStreak(days: completionDays, calendar: calendar)
        let lastSevenDays = (0..<7).map { offset -> Bool in
            let d = calendar.date(byAdding: .day, value: -(6 - offset), to: startToday)!
            return completionDays.contains(d)
        }

        // Quadrant distribution (always 4, Q1→Q4).
        let quadrantStats = Quadrant.allCases.map { q -> AnalyticsSummary.QuadrantStat in
            let inQ = tasks.filter { $0.quadrant == q }
            return .init(quadrant: q, total: inQ.count, completed: inQ.filter(\.completed).count)
        }

        // Tag stats (desc by count, then tag for stability; capped).
        // NOTE: the chain is split into typed bindings to avoid a Swift type-checker
        // timeout on the assembled `.map`/`.sorted`/`.prefix` expression. Behavior is
        // identical (count desc, tag asc tie-break, capped at topTagsLimit).
        var tagCounts: [String: Int] = [:]
        var tagCompleted: [String: Int] = [:]
        for t in tasks {
            for tag in t.tags {
                tagCounts[tag, default: 0] += 1
                if t.completed { tagCompleted[tag, default: 0] += 1 }
            }
        }
        let tagStats: [AnalyticsSummary.TagStat] =
            tagCounts.map { AnalyticsSummary.TagStat(tag: $0.key, count: $0.value, completed: tagCompleted[$0.key, default: 0]) }
        let sortedTags = tagStats.sorted { a, b in
            a.count == b.count ? a.tag < b.tag : a.count > b.count
        }
        let topTags = Array(sortedTags.prefix(topTagsLimit))

        // Deadlines (active only).
        let active = tasks.filter { !$0.completed }
        let overdueCount = active.filter { ($0.dueDate.map { $0 < startToday }) ?? false }.count
        let dueTodayCount = active.filter { ($0.dueDate.map { calendar.isDate($0, inSameDayAs: now) }) ?? false }.count
        let dueThisWeekCount = active.filter { ($0.dueDate.map { $0 >= startToday && $0 < weekEnd }) ?? false }.count
        let noDueDateCount = active.filter { $0.dueDate == nil }.count
        let datedActive = active.filter { ($0.dueDate.map { $0 >= startToday }) ?? false }
        let sortedDeadlines = datedActive.sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
        let upcomingDeadlines = Array(sortedDeadlines.prefix(upcomingLimit))

        // Completion trend (probe-pinned half-open buckets; index 0 = oldest, N-1 = today).
        let n = max(0, trendDays)
        let trend = (0..<n).map { i -> AnalyticsSummary.TrendPoint in
            let bucketStart = calendar.date(byAdding: .day, value: -(n - 1 - i), to: startToday)!
            let bucketEnd = calendar.date(byAdding: .day, value: 1, to: bucketStart)!
            let created = tasks.filter { $0.createdAt >= bucketStart && $0.createdAt < bucketEnd }.count
            let comp = tasks.filter { t in
                guard let at = t.completedAt else { return false }
                return at >= bucketStart && at < bucketEnd
            }.count
            return .init(date: bucketStart, created: created, completed: comp)
        }

        // Time tracking. Prefer the persisted `timeSpent`; fall back to recomputing from entries.
        func minutes(_ t: Task) -> Int { t.timeSpent ?? TimeTracking.timeSpentMinutes(t.timeEntries) }
        let totalTracked = tasks.reduce(0) { $0 + minutes($1) }
        let timeByQuadrant = Quadrant.allCases.map { q -> AnalyticsSummary.TimeByQuadrant in
            .init(quadrant: q, minutes: tasks.filter { $0.quadrant == q }.reduce(0) { $0 + minutes($1) })
        }

        // Estimate metrics. Accuracy is the literal spec ratio (global tracked over total
        // estimate); nil when nothing is estimated. Over/under compare per-task tracked vs
        // estimate only for tasks that have BOTH an estimate and tracked time > 0
        // (tracked == estimate is neither over nor under).
        let totalEstimated = tasks.compactMap(\.estimatedMinutes).reduce(0, +)
        let estimationAccuracy = totalEstimated == 0 ? nil : Double(totalTracked) / Double(totalEstimated)
        let estimatedAndTracked = tasks.compactMap { t -> (estimate: Int, tracked: Int)? in
            guard let estimate = t.estimatedMinutes, minutes(t) > 0 else { return nil }
            return (estimate, minutes(t))
        }
        let overEstimateCount = estimatedAndTracked.filter { $0.tracked > $0.estimate }.count
        let underEstimateCount = estimatedAndTracked.filter { $0.tracked < $0.estimate }.count

        return AnalyticsSummary(
            totalCount: total, activeCount: activeCount, completedCount: completedCount,
            completionRate: completionRate,
            completedToday: completedToday, completedThisWeek: completedThisWeek,
            completedThisMonth: completedThisMonth,
            activeStreak: activeStreak, longestStreak: longestStreak,
            lastSevenDays: lastSevenDays, quadrantStats: quadrantStats, topTags: topTags,
            overdueCount: overdueCount, dueTodayCount: dueTodayCount, dueThisWeekCount: dueThisWeekCount,
            noDueDateCount: noDueDateCount, upcomingDeadlines: upcomingDeadlines, trend: trend,
            totalTrackedMinutes: totalTracked, totalEstimatedMinutes: totalEstimated,
            estimationAccuracy: estimationAccuracy,
            overEstimateCount: overEstimateCount, underEstimateCount: underEstimateCount,
            timeByQuadrant: timeByQuadrant)
    }

    /// Consecutive completion days ending at today, or — when today is empty — starting
    /// at yesterday (LENIENT today-with-zero rule, probe-pinned). 0 when neither today
    /// nor yesterday has a completion.
    private static func activeStreak(startToday: Date, days: Set<Date>, calendar: Calendar) -> Int {
        var cursor = days.contains(startToday)
            ? startToday
            : calendar.date(byAdding: .day, value: -1, to: startToday)!
        var streak = 0
        while days.contains(cursor) {
            streak += 1
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor)!
        }
        return streak
    }

    /// Longest run of consecutive completion days over all history; 0 when none.
    private static func longestStreak(days: Set<Date>, calendar: Calendar) -> Int {
        guard !days.isEmpty else { return 0 }
        let sorted = days.sorted()
        var longest = 1, run = 1
        for i in 1..<sorted.count {
            if let next = calendar.date(byAdding: .day, value: 1, to: sorted[i - 1]), next == sorted[i] {
                run += 1; longest = max(longest, run)
            } else {
                run = 1
            }
        }
        return longest
    }
}
