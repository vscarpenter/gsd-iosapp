import Testing
import Foundation
import GSDModel
import GSDSnapshot

/// Watch spec 4.4: an action the watch app receives becomes a command; the iPhone route keeps
/// `ReminderActionInbox`. These pin the pure half of the watch route.
struct WatchReminderRouteTests {
    static let day: TimeInterval = 86_400
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let utc = TimeZone(identifier: "UTC")!

    private func row(_ id: String, urgent: Bool = true, important: Bool = true, due: Date? = nil) -> WatchTask {
        WatchTask(id: id, title: id, urgent: urgent, important: important, dueDate: due,
                  createdAt: now, updatedAt: now, isRecurring: false)
    }

    private func snapshot(_ tasks: [WatchTask], window: Int? = 2) -> WatchSnapshot {
        WatchSnapshot(generatedAt: now, escalationWindowDays: window, tasks: tasks,
                      doFirstTotal: 0, appliedCommandIDs: [])
    }

    // MARK: action to command

    @Test func completeButtonBecomesACompleteCommand() {
        #expect(WatchReminderRoute.kind(forAction: ReminderAction.completeID, taskID: "a") == .complete(taskID: "a"))
    }

    @Test func snoozeButtonBecomesASnoozeCommand() {
        #expect(WatchReminderRoute.kind(forAction: ReminderAction.snoozeID, taskID: "a") == .snooze(taskID: "a"))
    }

    @Test func aTapOrUnknownActionBecomesNothing() {
        #expect(WatchReminderRoute.kind(forAction: "com.apple.UNNotificationDefaultActionIdentifier", taskID: "a") == nil)
        #expect(WatchReminderRoute.kind(forAction: "dev.vinny.gsd.reminder.future", taskID: "a") == nil)
    }

    @Test func actionIDsKeepTheirShippedValues() {
        // Reminders already scheduled on a device match their category by these strings.
        #expect(ReminderAction.categoryID == "dev.vinny.gsd.reminder")
        #expect(ReminderAction.completeID == "dev.vinny.gsd.reminder.complete")
        #expect(ReminderAction.snoozeID == "dev.vinny.gsd.reminder.snooze1h")
    }

    // MARK: the notification scene

    @Test func sceneCardCarriesQuadrantDueAndEscalation() {
        let due = now.addingTimeInterval(Self.day)
        let card = WatchReminderRoute.card(for: "b", in: snapshot([row("b", urgent: false, due: due)]),
                                           now: now, timeZone: utc)
        #expect(card?.quadrant == .notUrgentImportant)
        #expect(card?.dueDate == due)
        #expect(card?.escalation.escalating == true)
    }

    @Test func sceneCardIsNilWhenTheSnapshotLacksTheTask() {
        #expect(WatchReminderRoute.card(for: "x", in: snapshot([]), now: now, timeZone: utc) == nil)
    }
}
