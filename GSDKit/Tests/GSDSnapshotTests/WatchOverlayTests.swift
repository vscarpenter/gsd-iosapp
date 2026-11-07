import Testing
import Foundation
import GSDModel
import GSDSnapshot

struct WatchOverlayTests {
    static let day: TimeInterval = 86_400
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let utc = TimeZone(identifier: "UTC")!
    var cal: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = utc; return c
    }

    private func row(_ id: String, urgent: Bool = true, important: Bool = true,
                     due: Date? = nil, recurring: Bool = false) -> WatchTask {
        WatchTask(id: id, title: id, urgent: urgent, important: important, dueDate: due,
                  createdAt: now, updatedAt: now, isRecurring: recurring)
    }

    private func snapshot(_ tasks: [WatchTask], window: Int? = 2, applied: [String] = []) -> WatchSnapshot {
        WatchSnapshot(generatedAt: now, escalationWindowDays: window, tasks: tasks,
                      doFirstTotal: tasks.filter { $0.urgent && $0.important }.count,
                      appliedCommandIDs: applied)
    }

    private func cmd(_ kind: WatchCommand.Kind, id: String, at offset: TimeInterval = 0) -> WatchCommand {
        WatchCommand(id: id, issuedAt: now.addingTimeInterval(offset), kind: kind)
    }

    private func lists(_ s: WatchSnapshot, _ pending: [WatchCommand]) -> WatchLists {
        WatchOverlay.apply(s, pending: pending, now: now, calendar: cal, timeZone: utc)
    }

    // MARK: lists without pending commands

    @Test func doFirstAndComingUpComeFromTheSharedRules() {
        let s = snapshot([
            row("doFirst"),
            row("soon", urgent: false, important: true, due: now.addingTimeInterval(Self.day)),
            row("far", urgent: false, important: true, due: now.addingTimeInterval(6 * Self.day)),
        ])
        let l = lists(s, [])
        #expect(l.doFirst.map(\.id) == ["doFirst"])
        #expect(l.comingUp.map(\.task.id) == ["soon"])
        #expect(l.comingUp.first?.escalation.target == .urgentImportant)
        #expect(l.pendingCount == 0)
    }

    @Test func comingUpIsEmptyWhenEscalationIsOff() {
        let s = snapshot([row("soon", urgent: false, due: now)], window: nil)
        #expect(lists(s, []).comingUp.isEmpty)
    }

    // MARK: each pending kind

    @Test func completeRemovesTheRow() {
        let l = lists(snapshot([row("a"), row("b")]), [cmd(.complete(taskID: "a"), id: "c1")])
        #expect(l.doFirst.map(\.id) == ["b"])
        #expect(l.pendingCount == 1)
    }

    @Test func markUrgentMovesAnEscalatingRowFromComingUpToDoFirst() {
        let s = snapshot([row("soon", urgent: false, important: true, due: now)])
        let l = lists(s, [cmd(.markUrgent(taskID: "soon"), id: "c1")])
        #expect(l.doFirst.map(\.id) == ["soon"])
        #expect(l.comingUp.isEmpty)
    }

    @Test func markUrgentOnANotImportantRowLeavesDoFirstAlone() {
        let s = snapshot([row("soon", urgent: false, important: false, due: now)])
        let l = lists(s, [cmd(.markUrgent(taskID: "soon"), id: "c1")])
        #expect(l.doFirst.isEmpty)           // it moves to Delegate, which the watch doesn't list
        #expect(l.comingUp.isEmpty)
    }

    @Test func captureAppearsInItsChosenQuadrantWithTheParsedTitle() {
        let l = lists(snapshot([]), [
            cmd(.capture(text: "Call Sam #home", quadrant: .urgentImportant), id: "c1"),
            cmd(.capture(text: "Someday idea", quadrant: .notUrgentImportant), id: "c2"),
        ])
        #expect(l.doFirst.map(\.title) == ["Call Sam"])
        #expect(l.pendingCount == 2)
    }

    @Test func snoozeAndTopThreeKindsChangeNoList() {
        let s = snapshot([row("a")])
        let before = lists(s, [])
        let after = lists(s, [cmd(.snooze(taskID: "a"), id: "c1"),
                              cmd(.addToToday(taskID: "a"), id: "c2"),
                              cmd(.removeFromToday(taskID: "a"), id: "c3")])
        #expect(after.doFirst == before.doFirst)
        #expect(after.pendingCount == 3)
    }

    @Test func completeThenReopenInOrderRestoresTheRow() {
        let l = lists(snapshot([row("a")]), [
            cmd(.complete(taskID: "a"), id: "c1", at: 0),
            cmd(.reopen(taskID: "a"), id: "c2", at: 5),
        ])
        #expect(l.doFirst.map(\.id) == ["a"])
    }

    // MARK: acknowledgement

    @Test func commandsInAppliedCommandIDsDropOut() {
        let s = snapshot([row("b")], applied: ["c1"])
        let l = lists(s, [cmd(.complete(taskID: "a"), id: "c1"), cmd(.complete(taskID: "b"), id: "c2")])
        #expect(l.pendingCount == 1)
        #expect(l.doFirst.isEmpty)           // c2 still hides b
    }

    // MARK: Undo

    @Test func undoBeforeTheCommandLeavesTheQueueRemovesIt() {
        let queued = [cmd(.complete(taskID: "a"), id: "c1")]
        #expect(WatchOverlay.undoComplete(commandID: "c1", of: row("a"), outbox: queued)
                == .removeFromOutbox(commandID: "c1"))
    }

    @Test func undoAfterTheCommandLeftQueuesAReopen() {
        #expect(WatchOverlay.undoComplete(commandID: "c1", of: row("a"), outbox: [])
                == .queueReopen(taskID: "a"))
    }

    @Test func undoOfARecurringTaskAfterTheCommandLeftIsUnavailable() {
        #expect(WatchOverlay.undoComplete(commandID: "c1", of: row("a", recurring: true), outbox: [])
                == .unavailable)
        // Still queued: removing it is clean even for a recurring task.
        let queued = [cmd(.complete(taskID: "a"), id: "c1")]
        #expect(WatchOverlay.undoComplete(commandID: "c1", of: row("a", recurring: true), outbox: queued)
                == .removeFromOutbox(commandID: "c1"))
    }
}
