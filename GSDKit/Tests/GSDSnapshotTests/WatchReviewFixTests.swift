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

    // MARK: WATCH-REVIEW-FIX 2: "+N more" follows the overlay

    private func lists(_ s: WatchSnapshot, _ pending: [WatchCommand]) -> WatchLists {
        WatchOverlay.apply(s, pending: pending, now: now, calendar: .current, timeZone: utc)
    }

    private func snapshot(_ tasks: [WatchTask], total: Int) -> WatchSnapshot {
        WatchSnapshot(generatedAt: now, escalationWindowDays: nil, tasks: tasks, doFirstTotal: total,
                      appliedCommandIDs: [])
    }

    @Test func completingOneOnAShortListLeavesNoPhantomMore() {
        let s = snapshot([row("a"), row("b"), row("c")], total: 3)
        let l = lists(s, [cmd("1", for: "a")])
        #expect(l.doFirst.count == 2)
        #expect(l.doFirstMore(rowLimit: 20, doFirstTotal: s.doFirstTotal) == 0)
    }

    @Test func aPendingDoFirstCaptureAddsToTheTotalNotToMore() {
        let s = snapshot([row("a"), row("b")], total: 2)
        let capture = WatchCommand(id: "c", issuedAt: now, kind: .capture(text: "new", quadrant: .urgentImportant))
        let l = lists(s, [capture])
        #expect(l.doFirst.count == 3)
        #expect(l.doFirstMore(rowLimit: 20, doFirstTotal: s.doFirstTotal) == 0)
    }

    @Test func morePastTheRowLimitStillShrinksWithAPendingComplete() {
        let tasks = (0..<25).map { row("\($0)") }
        let l = lists(snapshot(tasks, total: 120), [cmd("1", for: "0")])
        #expect(l.doFirstMore(rowLimit: 20, doFirstTotal: 120) == 99)
    }

    private func cmd(_ id: String, for taskID: String) -> WatchCommand {
        WatchCommand(id: id, issuedAt: now, kind: .complete(taskID: taskID))
    }

    // MARK: WATCH-REVIEW-FIX 3: one resend per activation

    @Test func aFailedCommandIsResentOnceThenLeftUntilTheNextActivation() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var outbox = WatchOutbox(directoryURL: dir)
        try outbox.add(cmd("a")); try outbox.add(cmd("b"))
        var ledger = WatchResendLedger()

        ledger.startActivation()
        #expect(ledger.take(from: outbox, excluding: []).map(\.id) == ["a", "b"])   // activation resend
        #expect(ledger.take(from: outbox, excluding: []).isEmpty)                    // failure: already resent
        ledger.startActivation()
        #expect(ledger.take(from: outbox, excluding: ["b"]).map(\.id) == ["a"])      // next activation
    }

    @Test func aFreshCommandThatFailsItsFirstSendIsResentOnce() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var outbox = WatchOutbox(directoryURL: dir)
        var ledger = WatchResendLedger()
        ledger.startActivation()
        _ = ledger.take(from: outbox, excluding: [])
        try outbox.add(cmd("late"))                       // queued after activation, first send failed
        #expect(ledger.take(from: outbox, excluding: []).map(\.id) == ["late"])
        #expect(ledger.take(from: outbox, excluding: []).isEmpty)
    }
}
