import Testing
import Foundation
@testable import GSDModel

struct TimeTrackingTests {
    private let epoch = Date(timeIntervalSince1970: 0)
    private func at(_ seconds: TimeInterval) -> Date { epoch.addingTimeInterval(seconds) }

    private func entry(_ id: String, start: TimeInterval, end: TimeInterval?) -> TimeEntry {
        TimeEntry(id: id, startedAt: at(start), endedAt: end.map(at))
    }

    @Test func startAddsRunningEntry() throws {
        var entries: [TimeEntry] = []
        entries = try TimeTracking.start(entries, now: at(0), newID: "te000001")
        #expect(entries.count == 1)
        #expect(entries[0].endedAt == nil)
        #expect(entries[0].startedAt == at(0))
    }

    @Test func startWhileRunningIsRejected() {
        let running = [entry("te000001", start: 0, end: nil)]
        #expect(throws: TimeTrackingError.alreadyRunning) {
            _ = try TimeTracking.start(running, now: at(10), newID: "te000002")
        }
    }

    @Test func stopClosesRunningEntry() throws {
        let running = [entry("te000001", start: 0, end: nil)]
        let stopped = try TimeTracking.stop(running, now: at(90))
        #expect(stopped[0].endedAt == at(90))
    }

    @Test func stopWithNoRunningEntryIsRejected() {
        let closed = [entry("te000001", start: 0, end: 60)]
        #expect(throws: TimeTrackingError.notRunning) {
            _ = try TimeTracking.stop(closed, now: at(90))
        }
    }

    @Test func runningEntryExposesTheOpenEntry() {
        let entries = [entry("a", start: 0, end: 60), entry("b", start: 70, end: nil)]
        #expect(TimeTracking.runningEntry(entries)?.id == "b")
    }

    @Test func timeSpentSumsCompletedEntriesInWholeMinutes() {
        // 90s + 150s = 240s = 4 min. A running entry contributes nothing.
        let entries = [entry("a", start: 0, end: 90),
                       entry("b", start: 100, end: 250),
                       entry("c", start: 300, end: nil)]
        #expect(TimeTracking.timeSpentMinutes(entries) == 4)
    }

    @Test func timeSpentFloorsPartialMinutes() {
        // 59s → 0; sum-then-floor (PROBE-VERIFIED scope call).
        #expect(TimeTracking.timeSpentMinutes([entry("a", start: 0, end: 59)]) == 0)
        #expect(TimeTracking.timeSpentMinutes([entry("a", start: 0, end: 119)]) == 1)
    }

    @Test func formatBoundaries() {
        #expect(TimeTracking.format(minutes: 0) == "< 1m")
        #expect(TimeTracking.format(minutes: 1) == "1m")
        #expect(TimeTracking.format(minutes: 59) == "59m")
        #expect(TimeTracking.format(minutes: 60) == "1h")
        #expect(TimeTracking.format(minutes: 61) == "1h 1m")
        #expect(TimeTracking.format(minutes: 120) == "2h")
        #expect(TimeTracking.format(minutes: 125) == "2h 5m")
    }
}
