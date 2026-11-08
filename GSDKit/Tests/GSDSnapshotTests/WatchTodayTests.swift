import Testing
import Foundation
import GSDModel
import GSDSnapshot

/// Watch spec 4.1 and 6.2 rule 3 (W6): the Today screen's rules, the pick fields on the wire, and
/// picks first in the rectangular widget. Picks and suggestions come from `TopThree`; these tests
/// pin that the watch only feeds it and draws what it returns.
struct WatchTodayTests {
    let utc = TimeZone(identifier: "UTC")!
    var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = utc; return c }
    /// 2027-01-15 08:00 UTC.
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let today = "2027-01-15"
    let yesterday = "2027-01-14"

    private func task(_ id: String, urgent: Bool = false, important: Bool = false,
                      due: Date? = nil, focusDate: String? = nil, focusRank: Int? = nil,
                      created: TimeInterval = 0) -> Task {
        Task(id: id, title: id, urgent: urgent, important: important,
             createdAt: Date(timeIntervalSince1970: created), updatedAt: Date(timeIntervalSince1970: 0),
             dueDate: due, focusDate: focusDate, focusRank: focusRank)
    }

    private func row(_ id: String, urgent: Bool = true, important: Bool = true,
                     focusDate: String? = nil, focusRank: Int? = nil) -> WatchTask {
        WatchTask(id: id, title: id, urgent: urgent, important: important,
                  createdAt: now, updatedAt: now, isRecurring: false,
                  focusDate: focusDate, focusRank: focusRank)
    }

    private func snap(_ rows: [WatchTask]) -> WatchSnapshot {
        WatchSnapshot(generatedAt: now, escalationWindowDays: 2, tasks: rows, doFirstTotal: rows.count,
                      appliedCommandIDs: [])
    }

    private func cmd(_ kind: WatchCommand.Kind, id: String = "c1", at offset: TimeInterval = 0) -> WatchCommand {
        WatchCommand(id: id, issuedAt: now.addingTimeInterval(offset), kind: kind)
    }

    private func today(_ s: WatchSnapshot, _ pending: [WatchCommand] = []) -> WatchToday {
        WatchOverlay.today(s, pending: pending, now: now, timeZone: utc)
    }

    // MARK: the pick fields cross the wire (spec 6.2 rule 3)

    @Test func theWatchRowCarriesTheFocusFieldsBothWays() {
        let original = task("a", focusDate: today, focusRank: 2)
        let mapped = WatchTask(original)
        #expect(mapped.focusDate == today && mapped.focusRank == 2)
        #expect(mapped.asTask.focusDate == today && mapped.asTask.focusRank == 2)
    }

    @Test func aWatchRowSurvivesJSONWithItsPick() throws {
        let data = try JSONEncoder().encode(row("a", focusDate: today, focusRank: 1))
        let back = try JSONDecoder().decode(WatchTask.self, from: data)
        #expect(back.focusDate == today && back.focusRank == 1)
    }

    private func build(_ tasks: [Task]) -> WatchSnapshot {
        WatchSnapshotBuilder.build(from: tasks, now: now, calendar: cal, escalationWindowDays: 2, appliedCommandIDs: [])
    }

    @Test func aPickDatedYesterdayOrLaterGoesInEvenOffTheUrgentLists() {
        // Delegate, Schedule, and Eliminate rows are not otherwise carried (rule 6.2 is unchanged).
        let snap = build([
            task("yesterday", urgent: true, important: false, focusDate: yesterday, focusRank: 1),
            task("today", important: true, focusDate: today, focusRank: 2),
            task("tomorrow", focusDate: "2027-01-16", focusRank: 3),
            task("twoDaysAgo", focusDate: "2027-01-13", focusRank: 1),
            task("plain", urgent: true, important: false),
        ])
        #expect(Set(snap.tasks.map(\.id)) == ["yesterday", "today", "tomorrow"])
    }

    @Test func overTheCapPicksStayAndTheRestKeepTheirOrder() {
        let filler = (0..<WatchSnapshot.taskCap).map { task("q\($0)", urgent: true, important: true, created: Double($0)) }
        let pick = task("pick", urgent: true, important: false, focusDate: today, focusRank: 1, created: 1_000)
        let snap = build(filler + [pick])
        #expect(snap.tasks.count == WatchSnapshot.taskCap)
        #expect(snap.tasks.first?.id == "pick")
        #expect(!snap.tasks.map(\.id).contains("q99"))
    }

    @Test func aCompletedPickIsStillLeftOut() {
        var done = task("done", urgent: true, important: true, focusDate: today, focusRank: 1)
        done.completed = true
        #expect(build([done]).tasks.isEmpty)
    }

    // MARK: Today rules (spec 4.1)

    @Test func picksComeInRankOrder() {
        let t = today(snap([row("c", focusDate: today, focusRank: 3), row("a", focusDate: today, focusRank: 1),
                            row("b", focusDate: today, focusRank: 2)]))
        #expect(t.picks.map(\.id) == ["a", "b", "c"])
        #expect(!t.canAdd)                          // full: Add to today is hidden
        #expect(t.suggestions.isEmpty)
    }

    @Test func yesterdaysPickIsNotShown() {
        let t = today(snap([row("old", focusDate: yesterday, focusRank: 1)]))
        #expect(t.picks.isEmpty)
    }

    @Test func noPicksOffersTheFirstThreeSuggestions() {
        let rows = (1...5).map { row("q\($0)") }
        let t = today(snap(rows))
        let expected = TopThree.suggest(rows.map(\.asTask), now: now, windowDays: 2, timeZone: utc).prefix(3)
        #expect(t.picks.isEmpty)
        #expect(t.suggestions.map(\.id) == Array(expected))
        #expect(t.suggestions.count == 3)
        #expect(t.canAdd)
    }

    @Test func withPicksTheSuggestionsAreNotOffered() {
        let t = today(snap([row("a", focusDate: today, focusRank: 1), row("b")]))
        #expect(t.picks.map(\.id) == ["a"])
        #expect(t.suggestions.isEmpty)
        #expect(t.canAdd)
    }

    @Test func twoDeviceConflictShowsThePicksWithoutATidyOffer() {
        let t = today(snap([row("a", focusDate: today, focusRank: 1), row("b", focusDate: today, focusRank: 1),
                            row("c", focusDate: today, focusRank: 2), row("d", focusDate: today, focusRank: 3)]))
        #expect(t.picks.count == 3)
    }

    @Test func aPendingCompleteRemovesAPick() {
        let s = snap([row("a", focusDate: today, focusRank: 1), row("b", focusDate: today, focusRank: 2)])
        #expect(today(s, [cmd(.complete(taskID: "a"))]).picks.map(\.id) == ["b"])
    }

    @Test func aPendingAddToTodayTakesTheNextFreeRank() {
        let s = snap([row("a", focusDate: today, focusRank: 1), row("b")])
        let t = today(s, [cmd(.addToToday(taskID: "b"))])
        #expect(t.picks.map(\.id) == ["a", "b"])
    }

    @Test func aPendingAddToTodayIsIgnoredWhenFull() {
        let s = snap([row("a", focusDate: today, focusRank: 1), row("b", focusDate: today, focusRank: 2),
                      row("c", focusDate: today, focusRank: 3), row("d")])
        #expect(today(s, [cmd(.addToToday(taskID: "d"))]).picks.map(\.id) == ["a", "b", "c"])
    }

    @Test func aPendingRemoveFromTodayDropsThePick() {
        let s = snap([row("a", focusDate: today, focusRank: 1), row("b", focusDate: today, focusRank: 2)])
        #expect(today(s, [cmd(.removeFromToday(taskID: "a"))]).picks.map(\.id) == ["b"])
    }

    @Test func anAcknowledgedCommandNoLongerApplies() {
        var s = snap([row("a", focusDate: today, focusRank: 1), row("b")])
        s.appliedCommandIDs = ["c1"]
        #expect(today(s, [cmd(.addToToday(taskID: "b"))]).picks.map(\.id) == ["a"])
    }

    // MARK: accessible names (spec 4.1)

    @Test func theSectionAndRowsReadTheirPlaceInThree() {
        let t = today(snap([row("a", focusDate: today, focusRank: 1), row("b", focusDate: today, focusRank: 2)]))
        #expect(t.sectionLabel == "Today, 2 of 3")
        #expect(t.rowLabel(at: 0) == "a, first")
        #expect(t.rowLabel(at: 1) == "b, second")
    }

    // MARK: rectangular widget shows picks first (W6)

    @Test func theWidgetShowsTodaysPicksBeforeDoFirst() {
        let s = snap([row("do1"), row("p2", urgent: false, focusDate: today, focusRank: 2),
                      row("p1", urgent: false, focusDate: today, focusRank: 1)])
        #expect(WatchWidgetContent.rectangular(s, now: now, calendar: cal, timeZone: utc) == .rows(["p1", "p2"]))
    }

    @Test func theWidgetFallsBackToDoFirstWithNoPicks() {
        let s = snap([row("do1"), row("old", urgent: false, focusDate: yesterday, focusRank: 1)])
        #expect(WatchWidgetContent.rectangular(s, now: now, calendar: cal, timeZone: utc) == .rows(["do1"]))
    }
}
