import Testing
import Foundation
import GSDModel
import GSDSnapshot

struct WidgetSnapshotBuilderTests {
    let now = Date(timeIntervalSince1970: 1_000_000)
    var cal: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }

    private func task(_ id: String, urgent: Bool, important: Bool,
                      completed: Bool = false, due: Date? = nil) -> Task {
        Task(id: id, title: id, urgent: urgent, important: important, completed: completed,
             createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0),
             dueDate: due)
    }

    @Test func includesOnlyUrgentImportantActive() {
        let tasks = [
            task("q1", urgent: true, important: true),
            task("q2", urgent: false, important: true),
            task("q3", urgent: true, important: false),
            task("q4", urgent: false, important: false),
            task("done", urgent: true, important: true, completed: true),
        ]
        let snap = WidgetSnapshotBuilder.todaysFocus(from: tasks, now: now, calendar: cal)
        #expect(snap.tasks.map(\.id) == ["q1"])
        #expect(snap.totalCount == 1)
    }

    @Test func sortsByDueDateAndRespectsLimitButCountsAll() {
        let day: TimeInterval = 86_400
        let tasks = (0..<10).map {
            task("t\($0)", urgent: true, important: true,
                 due: Date(timeIntervalSince1970: 1_000_000 + Double($0) * day))
        }
        let snap = WidgetSnapshotBuilder.todaysFocus(from: tasks, now: now, calendar: cal, limit: 3)
        #expect(snap.tasks.map(\.id) == ["t0", "t1", "t2"])  // earliest due first
        #expect(snap.totalCount == 10)                        // full match count, not the limit
    }

    @Test func emptyWhenNoMatches() {
        let snap = WidgetSnapshotBuilder.todaysFocus(
            from: [task("q4", urgent: false, important: false)], now: now, calendar: cal)
        #expect(snap.tasks.isEmpty)
        #expect(snap.totalCount == 0)
    }

    @Test func stampsGeneratedAtWithNow() {
        let snap = WidgetSnapshotBuilder.todaysFocus(from: [], now: now, calendar: cal)
        #expect(snap.generatedAt == now)
    }
}

/// Top three on the widget (spec-top-three section 9).
struct WidgetTopThreeTests {
    private let chicago = TimeZone(identifier: "America/Chicago")!
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = chicago; return c }
    private let now = ISO8601DateFormatter().date(from: "2026-11-04T16:00:00Z")!   // 10:00 in Chicago

    private func task(_ id: String, rank: Int?, on date: String? = "2026-11-04", urgent: Bool = false) -> Task {
        Task(id: id, title: id, urgent: urgent, important: true,
             createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0),
             focusDate: rank == nil ? nil : date, focusRank: rank)
    }

    @Test func picksComeFirstInRankOrder() {
        let snap = WidgetSnapshotBuilder.todaysFocus(
            from: [task("c", rank: 3), task("a", rank: 1), task("b", rank: 2)], now: now, calendar: calendar)
        #expect(snap.focusDate == "2026-11-04")
        #expect(snap.visibleFocusTasks(at: now, timeZone: chicago)?.map(\.id) == ["a", "b", "c"])
    }

    @Test func yesterdaysPicksFallBackToTheExistingList() {
        let snap = WidgetSnapshotBuilder.todaysFocus(
            from: [task("a", rank: 1, urgent: true)], now: now, calendar: calendar)
        let tomorrow = now.addingTimeInterval(86_400)
        #expect(snap.visibleFocusTasks(at: tomorrow, timeZone: chicago) == nil)   // drawn after midnight
        #expect(snap.tasks.map(\.id) == ["a"])                                     // the existing list is still there
    }

    @Test func picksDatedForAnotherDayAreNotShown() {
        let snap = WidgetSnapshotBuilder.todaysFocus(
            from: [task("a", rank: 1, on: "2026-11-03")], now: now, calendar: calendar)
        #expect(snap.focusTasks.isEmpty)
        #expect(snap.visibleFocusTasks(at: now, timeZone: chicago) == nil)
    }

    @Test func atMostThreeAreCarried() {
        let tasks = [task("a", rank: 1), task("b", rank: 2), task("c", rank: 3), task("d", rank: 3)]
        #expect(WidgetSnapshotBuilder.todaysFocus(from: tasks, now: now, calendar: calendar).focusTasks.count == 3)
    }

    @Test func aCompletedPickIsNotCarried() {
        var done = task("a", rank: 1); done.completed = true
        let snap = WidgetSnapshotBuilder.todaysFocus(from: [done, task("b", rank: 2)], now: now, calendar: calendar)
        #expect(snap.focusTasks.map(\.id) == ["b"])
    }

    @Test func aSnapshotWrittenBeforeTopThreeStillDecodes() throws {
        let old = #"{"generatedAt":0,"tasks":[{"id":"x","title":"x"}],"totalCount":1}"#
        let snap = try JSONDecoder().decode(WidgetSnapshot.self, from: Data(old.utf8))
        #expect(snap.focusDate == nil)
        #expect(snap.focusTasks.isEmpty)
        #expect(snap.visibleFocusTasks(at: now, timeZone: chicago) == nil)
    }

    @Test func theNextLocalMidnightKeepsTheWallClockAcrossAClockChange() {
        // Fall back: 2026-11-01 is 25 hours long in Chicago. Midnight is 2026-11-02 00:00 CST = 06:00Z.
        let before = ISO8601DateFormatter().date(from: "2026-11-01T18:00:00Z")!
        let next = WidgetSnapshot.nextLocalMidnight(after: before, timeZone: chicago)
        #expect(next == ISO8601DateFormatter().date(from: "2026-11-02T06:00:00Z"))
        #expect(WidgetSnapshot.nextLocalMidnight(after: now, timeZone: chicago)
                == ISO8601DateFormatter().date(from: "2026-11-05T06:00:00Z"))
    }

    @Test func roundTripsThroughJSON() throws {
        let snap = WidgetSnapshotBuilder.todaysFocus(from: [task("a", rank: 1)], now: now, calendar: calendar)
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(snap))
        #expect(decoded == snap)
    }
}
