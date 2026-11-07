import Testing
import Foundation
import GSDModel
import GSDSnapshot

struct WatchSnapshotBuilderTests {
    static let day: TimeInterval = 86_400
    let now = Date(timeIntervalSince1970: 1_800_000_000)   // 2027-01-15 08:00 UTC
    var cal: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }

    private func task(_ id: String, urgent: Bool = false, important: Bool = false,
                      completed: Bool = false, saved: Bool = false,
                      due: Date? = nil, created: TimeInterval = 0) -> Task {
        Task(id: id, title: id, urgent: urgent, important: important, completed: completed,
             createdAt: Date(timeIntervalSince1970: created), updatedAt: Date(timeIntervalSince1970: 0),
             dueDate: due, savedAt: saved ? Date(timeIntervalSince1970: 1) : nil)
    }

    private func build(_ tasks: [Task], window: Int? = 2, applied: [String] = []) -> WatchSnapshot {
        WatchSnapshotBuilder.build(from: tasks, now: now, calendar: cal,
                                   escalationWindowDays: window, appliedCommandIDs: applied)
    }

    // MARK: selection rules (spec 6.2)

    @Test func urgentAndImportantRowsAlwaysGoIn() {
        let snap = build([task("q1", urgent: true, important: true)])
        #expect(snap.tasks.map(\.id) == ["q1"])
    }

    @Test func notUrgentRowsDueWithinSevenDaysOrOverdueGoIn() {
        let snap = build([
            task("overdue", important: true, due: now.addingTimeInterval(-3 * Self.day)),
            task("in7", important: false, due: now.addingTimeInterval(7 * Self.day)),
            task("in8", important: true, due: now.addingTimeInterval(8 * Self.day)),
            task("noDue", important: true),
        ])
        #expect(Set(snap.tasks.map(\.id)) == ["overdue", "in7"])
    }

    @Test func urgentNotImportantRowsStayOff() {
        let snap = build([task("q3", urgent: true, important: false, due: now)])
        #expect(snap.tasks.isEmpty)
    }

    @Test func completedAndSavedRowsAreLeftOut() {
        let snap = build([
            task("done", urgent: true, important: true, completed: true),
            task("saved", urgent: true, important: true, saved: true),
            task("doneDue", important: true, completed: true, due: now),
            task("savedDue", important: true, saved: true, due: now),
        ])
        #expect(snap.tasks.isEmpty)
    }

    @Test func doFirstTotalCountsEveryTodaysFocusRowNotJustTheCappedOnes() {
        let many = (0..<130).map { task("q\($0)", urgent: true, important: true, created: Double($0)) }
        let snap = build(many)
        #expect(snap.tasks.count == 100)
        #expect(snap.doFirstTotal == 130)
    }

    // MARK: cap and order

    @Test func overTheCapKeepsEarliestDueThenCreatedAt() {
        // 100 rows due in two days, plus one due tomorrow and one due now. Created order is reversed.
        var tasks = (0..<100).map {
            task("late\($0)", urgent: true, important: true,
                 due: now.addingTimeInterval(2 * Self.day), created: Double(1000 - $0))
        }
        tasks.append(task("tomorrow", urgent: true, important: true, due: now.addingTimeInterval(Self.day)))
        tasks.append(task("today", urgent: true, important: true, due: now))
        let snap = build(tasks)
        #expect(snap.tasks.count == 100)
        #expect(snap.tasks.prefix(2).map(\.id) == ["today", "tomorrow"])
        // Ties on due date break by createdAt ascending: late99 was created first.
        #expect(snap.tasks[2].id == "late99")
        #expect(!snap.tasks.map(\.id).contains("late0"))
    }

    @Test func rowsWithNoDueDateSortAfterDatedRows() {
        let snap = build([
            task("none", urgent: true, important: true),
            task("dated", urgent: true, important: true, due: now),
        ])
        #expect(snap.tasks.map(\.id) == ["dated", "none"])
    }

    // MARK: carried fields

    @Test func carriesTheEscalationWindowAndAppliedIDsAndTheirCap() {
        let ids = (0..<60).map { "c\($0)" }
        let snap = build([], window: nil, applied: ids)
        #expect(snap.escalationWindowDays == nil)
        #expect(snap.appliedCommandIDs == Array(ids.suffix(50)))
        #expect(build([], window: 3).escalationWindowDays == 3)
        #expect(snap.version == 1)
        #expect(snap.generatedAt == now)
    }

    @Test func mapsTaskFieldsAndMarksRecurrence() {
        var t = task("r", urgent: true, important: true, due: now)
        t.recurrence = .weekly
        let row = build([t]).tasks[0]
        #expect(row.isRecurring)
        #expect(row.urgent && row.important)
        #expect(row.dueDate == now)
        #expect(row.focusDate == nil && row.focusRank == nil)
    }

    // MARK: forward compatibility (test 2)

    @Test func decodesAVersionOnePayloadWithPhaseFourFieldsMissing() throws {
        let json = """
        {"version":1,"generatedAt":0,"escalationWindowDays":2,"doFirstTotal":1,
         "appliedCommandIDs":[],
         "tasks":[{"id":"a","title":"A","urgent":true,"important":true,
                   "createdAt":0,"updatedAt":0,"isRecurring":false}]}
        """
        let snap = try JSONDecoder().decode(WatchSnapshot.self, from: Data(json.utf8))
        #expect(snap.tasks[0].focusDate == nil)
        #expect(snap.tasks[0].focusRank == nil)
        #expect(snap.tasks[0].dueDate == nil)
    }

    @Test func roundTripsThroughJSON() throws {
        let snap = build([task("a", urgent: true, important: true, due: now)], applied: ["x"])
        let back = try JSONDecoder().decode(WatchSnapshot.self, from: JSONEncoder().encode(snap))
        #expect(back == snap)
    }
}
