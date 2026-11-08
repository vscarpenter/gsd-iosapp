import Foundation
import GSDModel

/// What the watch app does with a reminder notification (watch spec 4.4). Pure, so the
/// routing is tested without a watch: the app layer only forwards `UNNotificationResponse`s.
public enum WatchReminderRoute {
    /// The command a reminder button becomes when the watch app receives the action. `nil` for
    /// any other identifier, so an unknown or future button is ignored rather than guessed at.
    /// The iPhone applies the command with the same checks as `ReminderActionHandler`
    /// (`WatchCommandPlan`), so a stale button is a skip, never a toggle back.
    public static func kind(forAction actionIdentifier: String, taskID: String) -> WatchCommand.Kind? {
        switch actionIdentifier {
        case ReminderAction.completeID: return .complete(taskID: taskID)
        case ReminderAction.snoozeID: return .snooze(taskID: taskID)
        default: return nil
        }
    }

    public enum List: Sendable, Equatable { case doFirst, comingUp }

    /// The list that holds the task, so a notification tap can open the watch app there.
    /// `nil` when the snapshot doesn't hold it (the app then opens on the home screen).
    public static func list(holding taskID: String, in lists: WatchLists) -> List? {
        if lists.doFirst.contains(where: { $0.id == taskID }) { return .doFirst }
        if lists.comingUp.contains(where: { $0.task.id == taskID }) { return .comingUp }
        return nil
    }

    /// What the notification scene draws under the reminder's title: quadrant, due time, and
    /// the escalation marker. Read from the watch's snapshot rather than the notification
    /// payload, so reminders already scheduled on a device keep working unchanged.
    public struct Card: Sendable, Equatable {
        public var quadrant: Quadrant
        public var dueDate: Date?
        public var escalation: Escalation.Result
    }

    /// `nil` when the snapshot doesn't hold the task (the scene then shows the system's title
    /// and body alone).
    public static func card(for taskID: String, in snapshot: WatchSnapshot,
                            now: Date, timeZone: TimeZone) -> Card? {
        guard let row = snapshot.tasks.first(where: { $0.id == taskID }) else { return nil }
        let task = row.asTask
        return Card(quadrant: task.quadrant, dueDate: row.dueDate,
                    escalation: Escalation.evaluate(task, now: now,
                                                    windowDays: snapshot.escalationWindowDays,
                                                    timeZone: timeZone))
    }
}
