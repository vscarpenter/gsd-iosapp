import Testing
import Foundation
@testable import GSDModel

struct AnalyticsEngineTests {
    /// Fixed UTC gregorian calendar; now = Mon 2026-06-15 09:00 UTC (matches the probe).
    /// `firstWeekday = 1` (Sunday) pins the week boundary so `.weekOfYear` metrics are
    /// deterministic across machines: the week of Mon 6/15 is [Sun 6/14, Sun 6/21).
    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = 1; return c
    }()
    private func day(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        var dc = DateComponents(); dc.year = y; dc.month = m; dc.day = d; dc.hour = h
        return cal.date(from: dc)!
    }
    private var now: Date { day(2026, 6, 15, 9) }

    private func task(_ id: String, urgent: Bool = false, important: Bool = false,
                      completed: Bool = false, completedAt: Date? = nil, due: Date? = nil,
                      tags: [String] = [], created: Date? = nil, estimate: Int? = nil,
                      entries: [TimeEntry] = [], timeSpent: Int? = nil) -> Task {
        Task(id: id, title: id, urgent: urgent, important: important, completed: completed,
             completedAt: completedAt, createdAt: created ?? day(2026, 6, 1),
             updatedAt: day(2026, 6, 1), dueDate: due, tags: tags,
             estimatedMinutes: estimate, timeSpent: timeSpent, timeEntries: entries)
    }
    private func compute(_ tasks: [Task], trendDays: Int = 7) -> AnalyticsSummary {
        AnalyticsEngine.compute(tasks: tasks, now: now, calendar: cal, trendDays: trendDays)
    }

    @Test func emptySetIsAllZeroWithoutCrashing() {
        let s = compute([])
        #expect(s.totalCount == 0 && s.activeCount == 0 && s.completedCount == 0)
        #expect(s.completionRate == 0)                 // div-by-zero guard
        #expect(s.activeStreak == 0 && s.longestStreak == 0)
        #expect(s.lastSevenDays == [false, false, false, false, false, false, false])
        #expect(s.quadrantStats.count == 4)            // always 4, even empty
        #expect(s.trend.count == 7)
        #expect(s.upcomingDeadlines.isEmpty && s.topTags.isEmpty)
        #expect(s.totalTrackedMinutes == 0)
    }
    @Test func countsAndCompletionRate() {
        let ts = [task("a"), task("b"), task("c", completed: true, completedAt: day(2026, 6, 15))]
        let s = compute(ts)
        #expect(s.totalCount == 3 && s.activeCount == 2 && s.completedCount == 1)
        #expect(abs(s.completionRate - (1.0 / 3.0)) < 1e-9)
    }
    @Test func quadrantStatsAreFourInOrderWithPerQuadrantCompletion() {
        let ts = [task("q1a", urgent: true, important: true),
                  task("q1b", urgent: true, important: true, completed: true, completedAt: day(2026, 6, 15)),
                  task("q4", urgent: false, important: false)]
        let s = compute(ts)
        #expect(s.quadrantStats.map(\.quadrant) == Quadrant.allCases)   // Q1→Q4
        let q1 = s.quadrantStats[0]
        #expect(q1.total == 2 && q1.completed == 1)
        #expect(abs(q1.completionRate - 0.5) < 1e-9)
        #expect(s.quadrantStats[1].total == 0 && s.quadrantStats[1].completionRate == 0)
    }
    @Test func activeStreakLenientTodayZero() {
        // today (6/15) has 0; yesterday 6/14 + 6/13 have completions → lenient active = 2.
        let ts = [task("a", completed: true, completedAt: day(2026, 6, 14)),
                  task("b", completed: true, completedAt: day(2026, 6, 13))]
        #expect(compute(ts).activeStreak == 2)
    }
    @Test func activeStreakCountsTodayWhenPresentAndGapBreaks() {
        let ts = [task("t", completed: true, completedAt: day(2026, 6, 15)),
                  task("y", completed: true, completedAt: day(2026, 6, 14)),
                  task("g", completed: true, completedAt: day(2026, 6, 12))]   // gap at 6/13
        #expect(compute(ts).activeStreak == 2)
    }
    @Test func longestStreakOverHistory() {
        let ts = [task("a", completed: true, completedAt: day(2026, 6, 1)),
                  task("b", completed: true, completedAt: day(2026, 6, 2)),
                  task("c", completed: true, completedAt: day(2026, 6, 3)),
                  task("d", completed: true, completedAt: day(2026, 6, 10))]
        #expect(compute(ts).longestStreak == 3)
    }
    @Test func lastSevenDaysArray() {
        let ts = [task("t", completed: true, completedAt: day(2026, 6, 15)),
                  task("m", completed: true, completedAt: day(2026, 6, 13)),
                  task("o", completed: true, completedAt: day(2026, 6, 9))]
        #expect(compute(ts).lastSevenDays == [true, false, false, false, true, false, true])
    }
    @Test func deadlineCounts() {
        let ts = [task("od", due: day(2026, 6, 14)),                       // overdue
                  task("today", due: day(2026, 6, 15)),                    // due today
                  task("w6", due: day(2026, 6, 21)),                       // this week (within +7)
                  task("doneOd", completed: true, completedAt: day(2026, 6, 14), due: day(2026, 6, 10))]
        let s = compute(ts)
        #expect(s.overdueCount == 1)      // completed-overdue excluded
        #expect(s.dueTodayCount == 1)
        #expect(s.dueThisWeekCount == 2)  // today + w6 (half-open [today, +7))
    }
    @Test func upcomingDeadlinesSortedActiveFutureDated() {
        let ts = [task("late", due: day(2026, 6, 25)),
                  task("soon", due: day(2026, 6, 16)),
                  task("od", due: day(2026, 6, 14)),                        // overdue excluded
                  task("none")]                                            // undated excluded
        #expect(compute(ts).upcomingDeadlines.map(\.id) == ["soon", "late"])
    }
    @Test func topTagsDescByCount() {
        let ts = [task("a", tags: ["home", "errand"]), task("b", tags: ["home"]),
                  task("c", tags: ["home", "errand"]), task("d", tags: ["work"])]
        let s = compute(ts)
        #expect(s.topTags.first?.tag == "home" && s.topTags.first?.count == 3)
        #expect(Set(s.topTags.map(\.tag)) == ["home", "errand", "work"])
    }
    @Test func trendBuckets() {
        let ts = [task("a", created: day(2026, 6, 15)),
                  task("b", completed: true, completedAt: day(2026, 6, 14), created: day(2026, 6, 9))]
        let s = compute(ts, trendDays: 7)
        #expect(s.trend.count == 7)
        #expect(s.trend.first?.date == cal.startOfDay(for: day(2026, 6, 9)))
        #expect(s.trend.last?.created == 1)                                // today (6/15)
        #expect(s.trend.first?.created == 1)                               // 6/9
        let b14 = s.trend.first { $0.date == cal.startOfDay(for: day(2026, 6, 14)) }!
        #expect(b14.completed == 1)
    }
    @Test func trendHonorsRequestedLength() {
        #expect(compute([], trendDays: 30).trend.count == 30)
        #expect(compute([], trendDays: 90).trend.count == 90)
    }
    @Test func timeTrackingSummary() {
        // 90 minutes in Q1 (via timeSpent), 30 minutes in Q4 (via a closed entry).
        let q1 = task("q1", urgent: true, important: true, timeSpent: 90)
        let q4 = task("q4", entries: [TimeEntry(id: "e", startedAt: day(2026, 6, 1, 10),
                                                endedAt: day(2026, 6, 1, 10).addingTimeInterval(30 * 60))])
        let s = compute([q1, q4])
        #expect(s.totalTrackedMinutes == 120)
        #expect(s.timeByQuadrant.count == 4)
        #expect(s.timeByQuadrant[0].minutes == 90)   // Q1
        #expect(s.timeByQuadrant[3].minutes == 30)   // Q4
    }
    @Test func periodCompletionCounts() {
        // Week of now (6/15) is [Sun 6/14, 6/21); month is June.
        let ts = [task("today", completed: true, completedAt: day(2026, 6, 15)),
                  task("thisWeek", completed: true, completedAt: day(2026, 6, 14)),   // Sun, in-week not today
                  task("lastMonth", completed: true, completedAt: day(2026, 5, 20)),
                  task("noDate", completed: true, completedAt: nil)]                   // no completedAt → excluded
        let s = compute(ts)
        #expect(s.completedToday == 1)               // 6/15 only
        #expect(s.completedThisWeek == 2)            // 6/15 + 6/14
        #expect(s.completedThisMonth == 2)           // 6/15 + 6/14 (May excluded)
    }
    @Test func tagCompletedAndRate() {
        let ts = [task("a", completed: true, completedAt: day(2026, 6, 15), tags: ["home"]),
                  task("b", tags: ["home"])]
        let home = compute(ts).topTags.first { $0.tag == "home" }!
        #expect(home.count == 2 && home.completed == 1)
        #expect(abs(home.rate - 0.5) < 1e-9)
    }
    @Test func noDueDateCountIsActiveOnly() {
        let ts = [task("activeNoDue"),                                                 // counts
                  task("doneNoDue", completed: true, completedAt: day(2026, 6, 15)),   // completed → excluded
                  task("dated", due: day(2026, 6, 20))]                                // has due → excluded
        #expect(compute(ts).noDueDateCount == 1)
    }
    @Test func estimateMetricsWithBoundary() {
        // over: tracked 120 > est 60; under: tracked 30 < est 90; exact: tracked 45 == est 45 (neither);
        // noEstTracked: 40 tracked, no estimate → adds to numerator only.
        let ts = [task("over", estimate: 60, timeSpent: 120),
                  task("under", estimate: 90, timeSpent: 30),
                  task("exact", estimate: 45, timeSpent: 45),
                  task("noEstTracked", timeSpent: 40)]
        let s = compute(ts)
        #expect(s.totalEstimatedMinutes == 195)                     // 60 + 90 + 45
        #expect(s.totalTrackedMinutes == 235)                       // 120 + 30 + 45 + 40
        #expect(abs((s.estimationAccuracy ?? -1) - (235.0 / 195.0)) < 1e-9)  // global tracked / total est
        #expect(s.overEstimateCount == 1)                           // over only
        #expect(s.underEstimateCount == 1)                          // under only (exact is neither)
    }
    @Test func estimationAccuracyNilWhenNoEstimates() {
        #expect(compute([task("a", timeSpent: 30)]).estimationAccuracy == nil)
        #expect(compute([]).estimationAccuracy == nil)
        #expect(compute([]).totalEstimatedMinutes == 0)
    }
}
