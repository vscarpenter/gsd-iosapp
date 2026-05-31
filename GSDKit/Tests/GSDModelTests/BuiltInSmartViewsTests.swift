import Testing
import Foundation
@testable import GSDModel

struct BuiltInSmartViewsTests {
    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }()
    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d; c.hour = 12
        return cal.date(from: c)!
    }
    private var now: Date { day(2026, 6, 15) }
    private func t(_ id: String, urgent: Bool = false, important: Bool = false,
                   completed: Bool = false, completedAt: Date? = nil, due: Date? = nil,
                   recurrence: RecurrenceType = .none, deps: [String] = [], created: Date? = nil) -> Task {
        Task(id: id, title: id, urgent: urgent, important: important, completed: completed,
             completedAt: completedAt, createdAt: created ?? Date(timeIntervalSince1970: 0),
             updatedAt: Date(timeIntervalSince1970: 0), dueDate: due, recurrence: recurrence, dependencies: deps)
    }
    private func view(_ id: String) -> SmartView { BuiltInSmartViews.all.first { $0.id == id }! }
    private func ids(_ id: String, _ tasks: [Task]) -> Set<String> {
        Set(TaskFilter.apply(view(id).criteria, to: tasks, now: now, calendar: cal).map(\.id))
    }

    @Test func thereAreNineStableBuiltIns() {
        #expect(BuiltInSmartViews.all.count == 9)
        #expect(BuiltInSmartViews.all.allSatisfy { $0.isBuiltIn })
        #expect(BuiltInSmartViews.all.map(\.id) ==
                ["today-focus", "this-week", "overdue", "no-deadline", "recently-added",
                 "weeks-wins", "all-completed", "recurring", "ready-to-work"])
    }
    @Test func todaysFocusIsActiveQ1() {
        let ts = [t("q1", urgent: true, important: true), t("q2", important: true),
                  t("done", urgent: true, important: true, completed: true)]
        #expect(ids("today-focus", ts) == ["q1"])
    }
    @Test func overdueBacklog() {
        let ts = [t("od", due: day(2026, 6, 14)), t("future", due: day(2026, 6, 20))]
        #expect(ids("overdue", ts) == ["od"])
    }
    @Test func recurringTasksView() {
        let ts = [t("w", recurrence: .weekly), t("none")]
        #expect(ids("recurring", ts) == ["w"])
    }
    @Test func readyToWorkView() {
        let ts = [t("blocked", deps: ["x"]), t("x"), t("free")]
        #expect(ids("ready-to-work", ts) == ["x", "free"])
    }
    @Test func weeksWinsIsRecentlyCompleted() {
        let ts = [t("won", completed: true, completedAt: day(2026, 6, 12)),
                  t("oldwin", completed: true, completedAt: day(2026, 6, 1))]
        #expect(ids("weeks-wins", ts) == ["won"])
    }
}
