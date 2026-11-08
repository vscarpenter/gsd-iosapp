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

    private func row(_ id: String, urgent: Bool = true, important: Bool = true, due: Date? = nil) -> WatchTask {
        WatchTask(id: id, title: id, urgent: urgent, important: important, dueDate: due,
                  createdAt: now, updatedAt: now, isRecurring: false)
    }

    private func snap(_ tasks: [WatchTask]) -> WatchSnapshot {
        WatchSnapshot(generatedAt: now, escalationWindowDays: nil, tasks: tasks, doFirstTotal: tasks.count,
                      appliedCommandIDs: [])
    }

    private func rows(_ s: WatchSnapshot, at date: Date? = nil) -> [String] {
        if case .rows(let titles) = WatchWidgetContent.rectangular(s, now: date ?? now, calendar: cal, timeZone: utc) {
            return titles
        }
        return []
    }

    // MARK: rectangular

    @Test func rectangularShowsUpToThreeDoFirstRows() {
        #expect(rows(snap([row("a"), row("b"), row("c"), row("d")])) == ["a", "b", "c"])
    }

    @Test func rectangularIsClearWhenAFreshSnapshotHasNothing() {
        #expect(WatchWidgetContent.rectangular(snap([]), now: now, calendar: cal, timeZone: utc) == .clear)
    }

    @Test func rectangularAsksForThePhoneBeforeTheFirstSnapshot() {
        #expect(WatchWidgetContent.rectangular(nil, now: now, calendar: cal, timeZone: utc) == .needsPhone)
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

    @Test func inlineMovesOnAtTheDueTime() {
        // At 11:00 sharp the 11:00 task has arrived; the line shows the next one, not the past one.
        let s = snap([row("eleven", due: at(11)), row("three", due: at(15))])
        #expect(WatchWidgetContent.inline(s, now: at(11), calendar: cal)?.title == "three")
        #expect(WatchWidgetContent.inline(snap([row("eleven", due: at(11))]), now: at(11), calendar: cal) == nil)
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

    @Test func relevanceSkipsAnAllDayTaskEvenAtMidnightSharp() {
        // An all-day task is due at 00:00, so only at 00:00 sharp does it pass the "not yet past" check.
        let s = snap([row("allDay", due: at(0)), row("timed", due: at(8))])
        let windows = WatchWidgetContent.relevanceIntervals(s, now: at(0), calendar: cal)
        #expect(windows.count == 1)
        #expect(windows[0].end == at(8).addingTimeInterval(15 * 60))
    }

    @Test func relevanceIsCappedSoItNeverFillsTheDay() {
        let many = (0..<12).map { row("t\($0)", due: at(10, $0 * 5)) }
        #expect(WatchWidgetContent.relevanceLimit == 5)
        #expect(WatchWidgetContent.relevanceIntervals(snap(many), now: now, calendar: cal).count == 5)
    }

    // MARK: capture request

    private func defaults() -> UserDefaults { UserDefaults(suiteName: "t.\(UUID().uuidString)")! }

    @Test func captureRequestIsConsumedOnce() {
        let d = defaults()
        #expect(!WatchCaptureRequest.consume(from: d, now: now))
        WatchCaptureRequest.request(in: d, now: now)
        #expect(WatchCaptureRequest.consume(from: d, now: now.addingTimeInterval(5)))
        #expect(!WatchCaptureRequest.consume(from: d, now: now.addingTimeInterval(6)))
    }

    @Test func captureRequestWithinTheLimitIsHonored() {
        let d = defaults()
        WatchCaptureRequest.request(in: d, now: now)
        #expect(WatchCaptureRequest.consume(from: d, now: now.addingTimeInterval(WatchCaptureRequest.maxAge)))
    }

    @Test func aStaleCaptureRequestIsIgnoredAndCleared() {
        let d = defaults()
        WatchCaptureRequest.request(in: d, now: now)
        #expect(!WatchCaptureRequest.consume(from: d, now: now.addingTimeInterval(WatchCaptureRequest.maxAge + 1)))
        // Cleared too, so it can't fire on a later launch.
        #expect(!WatchCaptureRequest.consume(from: d, now: now))
    }
}
