import Testing
import Foundation
import GSDModel
import GSDSnapshot

/// Watch spec 4.5: what each widget family draws, when the timeline redraws, and when the
/// Smart Stack should surface the widget. All pure, so the rules run without a watch.
struct WatchWidgetContentTests {
    let utc = TimeZone(identifier: "UTC")!
    var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = utc; return c }
    /// 2027-01-15 09:00 UTC.
    let now = Date(timeIntervalSince1970: 1_800_090_000)

    private func at(_ hour: Int, _ minute: Int = 0, dayOffset: Int = 0) -> Date {
        let start = cal.startOfDay(for: now)
        let day = cal.date(byAdding: .day, value: dayOffset, to: start)!
        return cal.date(from: DateComponents(timeZone: utc, year: cal.component(.year, from: day),
                                              month: cal.component(.month, from: day),
                                              day: cal.component(.day, from: day), hour: hour, minute: minute))!
    }

    private func row(_ id: String, urgent: Bool = true, important: Bool = true, due: Date? = nil,
                     focusDate: String? = nil, focusRank: Int? = nil) -> WatchTask {
        WatchTask(id: id, title: id, urgent: urgent, important: important, dueDate: due,
                  createdAt: now, updatedAt: now, isRecurring: false, focusDate: focusDate, focusRank: focusRank)
    }

    private func snap(_ tasks: [WatchTask]) -> WatchSnapshot {
        WatchSnapshot(generatedAt: now, escalationWindowDays: nil, tasks: tasks, doFirstTotal: tasks.count,
                      appliedCommandIDs: [])
    }

    private func rows(_ s: WatchSnapshot, at date: Date? = nil) -> [String] {
        WatchWidgetContent.rectangularTitles(s, now: date ?? now, calendar: cal, timeZone: utc)
    }

    // MARK: rectangular

    @Test func rectangularShowsUpToThreeDoFirstRows() {
        #expect(rows(snap([row("a"), row("b"), row("c"), row("d")])) == ["a", "b", "c"])
    }

    @Test func rectangularPrefersTodaysPicksInRankOrder() {
        let today = TopThree.localDate(now, timeZone: utc)
        let s = snap([row("x"), row("p2", urgent: false, focusDate: today, focusRank: 2),
                      row("p1", urgent: false, focusDate: today, focusRank: 1)])
        #expect(rows(s) == ["p1", "p2"])
    }

    @Test func aPickDatedYesterdayIsNeverShown() {
        let yesterday = TopThree.localDate(at(9, dayOffset: -1), timeZone: utc)
        let s = snap([row("old", urgent: false, focusDate: yesterday, focusRank: 1)])
        #expect(rows(s).isEmpty)
    }

    @Test func rectangularIsEmptyWhenNothingMatches() {
        #expect(rows(snap([])).isEmpty)
    }

    // MARK: inline

    @Test func inlineIsTheNextTimedTaskDueToday() {
        let s = snap([row("late", due: at(15)), row("soon", due: at(11)), row("past", due: at(8)),
                      row("allDay", due: at(0)), row("tomorrow", due: at(10, dayOffset: 1))])
        let line = WatchWidgetContent.inline(s, now: now, calendar: cal)
        #expect(line?.title == "soon")
        #expect(line?.time == at(11))
    }

    @Test func inlineIsNilWhenNothingTimedRemains() {
        #expect(WatchWidgetContent.inline(snap([row("past", due: at(8)), row("allDay", due: at(0))]),
                                          now: now, calendar: cal) == nil)
    }

    // MARK: timeline

    @Test func timelineHasNowEachRemainingDueTimeAndMidnight() {
        let s = snap([row("a", due: at(11)), row("b", due: at(8)), row("c", due: at(15))])
        let dates = WatchWidgetContent.timelineDates(s, now: now, calendar: cal)
        #expect(dates == [now, at(11), at(15), at(0, dayOffset: 1)])
    }

    @Test func timelineAlwaysEndsAtTheNextMidnight() {
        let dates = WatchWidgetContent.timelineDates(snap([]), now: now, calendar: cal)
        #expect(dates == [now, at(0, dayOffset: 1)])
    }

    // MARK: relevance

    @Test func relevanceWindowsSurroundTheRemainingDueTimesOnly() {
        let s = snap([row("a", due: at(11)), row("past", due: at(8)), row("allDay", due: at(0))])
        let windows = WatchWidgetContent.relevanceIntervals(s, now: now, calendar: cal)
        #expect(windows.count == 1)
        #expect(windows[0].start < at(11) && windows[0].end > at(11))
        #expect(windows[0].duration < 3_600 * 2)   // never claims the stack for the day
    }

    @Test func relevanceIsCappedSoItNeverFillsTheDay() {
        let many = (0..<12).map { row("t\($0)", due: at(10, $0 * 5)) }
        #expect(WatchWidgetContent.relevanceIntervals(snap(many), now: now, calendar: cal).count
                <= WatchWidgetContent.relevanceLimit)
    }

    // MARK: capture request

    @Test func captureRequestIsConsumedOnce() {
        let defaults = UserDefaults(suiteName: "t.\(UUID().uuidString)")!
        #expect(!WatchCaptureRequest.consume(from: defaults))
        WatchCaptureRequest.request(in: defaults)
        #expect(WatchCaptureRequest.consume(from: defaults))
        #expect(!WatchCaptureRequest.consume(from: defaults))
    }
}
