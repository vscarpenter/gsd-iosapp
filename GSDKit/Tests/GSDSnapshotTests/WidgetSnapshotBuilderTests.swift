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
