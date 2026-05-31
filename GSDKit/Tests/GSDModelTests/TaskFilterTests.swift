import Testing
import Foundation
@testable import GSDModel

struct TaskFilterTests {
    /// Fixed UTC gregorian calendar; now = Mon 2026-06-15 09:00 UTC.
    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }()
    private func day(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d; c.hour = h
        return Calendar(identifier: .gregorian).date(from: { var x = c; return x }())!
    }
    private var now: Date { day(2026, 6, 15, 9) }

    private func task(_ id: String, urgent: Bool = false, important: Bool = false,
                      completed: Bool = false, completedAt: Date? = nil,
                      due: Date? = nil, recurrence: RecurrenceType = .none,
                      tags: [String] = [], deps: [String] = [], created: Date? = nil,
                      title: String = "", description: String = "",
                      subtasks: [Subtask] = []) -> Task {
        Task(id: id, title: title.isEmpty ? id : title, description: description,
             urgent: urgent, important: important, completed: completed, completedAt: completedAt,
             createdAt: created ?? Date(timeIntervalSince1970: 0),
             updatedAt: Date(timeIntervalSince1970: 0),
             dueDate: due, recurrence: recurrence, tags: tags, subtasks: subtasks, dependencies: deps)
    }
    private func ids(_ c: FilterCriteria, _ tasks: [Task]) -> Set<String> {
        Set(TaskFilter.apply(c, to: tasks, now: now, calendar: cal).map(\.id))
    }

    @Test func emptyCriteriaMatchesAll() {
        let ts = [task("a"), task("b", completed: true)]
        #expect(ids(FilterCriteria(), ts) == ["a", "b"])
    }
    @Test func statusActiveAndCompleted() {
        let ts = [task("a"), task("b", completed: true)]
        #expect(ids(FilterCriteria(status: .active), ts) == ["a"])
        #expect(ids(FilterCriteria(status: .completed), ts) == ["b"])
    }
    @Test func quadrantsMembership() {
        let ts = [task("q1", urgent: true, important: true), task("q4")]
        #expect(ids(FilterCriteria(quadrants: [.urgentImportant]), ts) == ["q1"])
    }
    @Test func tagsRequiresAll() {
        let ts = [task("a", tags: ["home", "errand"]), task("b", tags: ["home"])]
        #expect(ids(FilterCriteria(tags: ["home", "errand"]), ts) == ["a"])
    }
    @Test func recurrenceMembership() {
        let ts = [task("d", recurrence: .daily), task("n", recurrence: .none)]
        #expect(ids(FilterCriteria(recurrence: [.daily, .weekly, .monthly]), ts) == ["d"])
    }
    @Test func overdueRequiresActivePastDue() {
        let ts = [task("od", due: day(2026, 6, 14)), task("done", completed: true, due: day(2026, 6, 14)),
                  task("today", due: day(2026, 6, 15))]
        #expect(ids(FilterCriteria(overdue: true), ts) == ["od"])
    }
    @Test func dueTodayAndThisWeekHalfOpen() {
        let ts = [task("t", due: day(2026, 6, 15)), task("w6", due: day(2026, 6, 21)),
                  task("w7", due: day(2026, 6, 22))]
        #expect(ids(FilterCriteria(dueToday: true), ts) == ["t"])
        #expect(ids(FilterCriteria(dueThisWeek: true), ts) == ["t", "w6"]) // +7d excluded
    }
    @Test func noDueDate() {
        let ts = [task("none"), task("has", due: day(2026, 6, 20))]
        #expect(ids(FilterCriteria(noDueDate: true), ts) == ["none"])
    }
    @Test func dueDateRangeInclusive() {
        let ts = [task("in", due: day(2026, 6, 18)), task("out", due: day(2026, 7, 1))]
        let c = FilterCriteria(dueDateRange: .init(start: day(2026, 6, 1), end: day(2026, 6, 30)))
        #expect(ids(c, ts) == ["in"])
    }
    @Test func recentlyAddedAndCompleted() {
        let ts = [task("new", created: day(2026, 6, 12)), task("old", created: day(2026, 6, 1)),
                  task("won", completed: true, completedAt: day(2026, 6, 12)),
                  task("oldwin", completed: true, completedAt: day(2026, 6, 1))]
        #expect(ids(FilterCriteria(recentlyAdded: true), ts) == ["new"])
        #expect(ids(FilterCriteria(recentlyCompleted: true), ts) == ["won"])
    }
    @Test func readyToWorkUsesFullSet() {
        // a depends on b (incomplete) → blocked; c depends on d (complete) → ready.
        let ts = [task("a", deps: ["b"]), task("b"),
                  task("c", deps: ["d"]), task("d", completed: true)]
        // Even though status:.active would drop d from the result, d must still resolve as a completed blocker.
        #expect(ids(FilterCriteria(status: .active, readyToWork: true), ts) == ["b", "c"])
    }
    @Test func searchAcrossTitleDescriptionTagsAndSubtasks() {
        let ts = [task("t1", title: "Buy milk"),
                  task("t2", description: "call the MILKman"),
                  task("t3", tags: ["dairy-milk"]),
                  task("t4", subtasks: [Subtask(id: "s", title: "skim milk", completed: false)]),
                  task("t5", title: "unrelated")]
        #expect(ids(FilterCriteria(searchQuery: "milk"), ts) == ["t1", "t2", "t3", "t4"])
        #expect(ids(FilterCriteria(searchQuery: "  "), ts).count == 5) // whitespace = no constraint
    }
    @Test func criteriaAreANDed() {
        let ts = [task("a", urgent: true, important: true, tags: ["work"]),
                  task("b", urgent: true, important: true, tags: ["home"])]
        #expect(ids(FilterCriteria(quadrants: [.urgentImportant], tags: ["work"]), ts) == ["a"])
    }

    @Test func activeResultsSortByDueDateAscNilLast() {
        let ts = [task("late", due: day(2026, 6, 25)), task("none"),
                  task("soon", due: day(2026, 6, 16))]
        let r = TaskFilter.apply(FilterCriteria(status: .active), to: ts, now: now, calendar: cal)
        #expect(r.map(\.id) == ["soon", "late", "none"]) // due asc, nil last
    }
    @Test func completedResultsSortByCompletedAtDesc() {
        let ts = [task("old", completed: true, completedAt: day(2026, 6, 1)),
                  task("new", completed: true, completedAt: day(2026, 6, 14))]
        let r = TaskFilter.apply(FilterCriteria(status: .completed), to: ts, now: now, calendar: cal)
        #expect(r.map(\.id) == ["new", "old"])
    }
    @Test func dueDateTieBreaksByCreatedAtDesc() {
        let d = day(2026, 6, 20)
        let ts = [task("older", due: d, created: day(2026, 6, 1)),
                  task("newer", due: d, created: day(2026, 6, 10))]
        let r = TaskFilter.apply(FilterCriteria(status: .active), to: ts, now: now, calendar: cal)
        #expect(r.map(\.id) == ["newer", "older"])
    }
}
