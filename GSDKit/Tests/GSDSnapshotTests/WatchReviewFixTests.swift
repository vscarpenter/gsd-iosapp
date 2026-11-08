import Testing
import Foundation
import GSDModel
import GSDSnapshot

/// W3-FIX (review of #96): resend, the capture title limit, and the "+N more" count.
struct WatchReviewFixTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let utc = TimeZone(identifier: "UTC")!

    private func cmd(_ id: String) -> WatchCommand {
        WatchCommand(id: id, issuedAt: now, kind: .complete(taskID: "t"))
    }

    private func row(_ id: String) -> WatchTask {
        WatchTask(id: id, title: id, urgent: true, important: true, createdAt: now, updatedAt: now, isRecurring: false)
    }

    // MARK: 1. resend

    @Test func resendsOnlyCommandsNotAlreadyInFlight() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var outbox = WatchOutbox(directoryURL: dir)
        try outbox.add(cmd("a")); try outbox.add(cmd("b")); try outbox.add(cmd("c"))
        #expect(outbox.unsent(excluding: ["b"]).map(\.id) == ["a", "c"])
        #expect(outbox.unsent(excluding: []).map(\.id) == ["a", "b", "c"])
    }

    @Test func commandWireRoundTripsThroughTheSharedKey() throws {
        let payload = try #require(WatchWire.userInfo(for: cmd("a")))
        #expect(WatchWire.command(from: payload)?.id == "a")
        #expect(WatchWire.command(from: ["other": 1]) == nil)
    }

    // MARK: 2. capture title limit

    @Test func overlayShowsTheSameClampedTitleAsThePhone() {
        let long = String(repeating: "x", count: 120)
        let snap = WatchSnapshot(generatedAt: now, escalationWindowDays: nil, tasks: [],
                                 doFirstTotal: 0, appliedCommandIDs: [])
        let c = WatchCommand(id: "c", issuedAt: now, kind: .capture(text: long, quadrant: .urgentImportant))
        let lists = WatchOverlay.apply(snap, pending: [c], now: now, calendar: .current, timeZone: utc)
        #expect(lists.doFirst.first?.title.count == FieldLimits.titleRange.upperBound)
    }

    @Test func captureOverTheLimitIsFlagged() {
        #expect(WatchCommandPlan.captureOverLimit(String(repeating: "x", count: 81)))
        #expect(!WatchCommandPlan.captureOverLimit(String(repeating: "x", count: 80)))
        #expect(!WatchCommandPlan.captureOverLimit("   "))
    }

    // MARK: 3. "+N more on iPhone"

    @Test func moreCountsAgainstTheIPhoneTotalPastTheRowLimit() {
        let lists = WatchLists(doFirst: (0..<25).map { row("\($0)") }, comingUp: [], pendingCount: 0)
        #expect(lists.doFirstMore(rowLimit: 20, doFirstTotal: 120) == 100)
    }

    @Test func moreFallsBackToTheListWhenItIsLargerThanTheTotal() {
        let lists = WatchLists(doFirst: (0..<25).map { row("\($0)") }, comingUp: [], pendingCount: 0)
        #expect(lists.doFirstMore(rowLimit: 20, doFirstTotal: 3) == 5)
        let short = WatchLists(doFirst: (0..<3).map { row("\($0)") }, comingUp: [], pendingCount: 0)
        #expect(short.doFirstMore(rowLimit: 20, doFirstTotal: 3) == 0)
        #expect(short.doFirstMore(rowLimit: 20, doFirstTotal: 7) == 4)
    }
}
