import Foundation
import GSDModel

/// Identifiers for the buttons on a reminder notification (B-17). Strings only, so the
/// App target can build its `UNNotificationCategory` from them without this module
/// importing `UserNotifications`.
public enum ReminderAction {
    public static let categoryID = "dev.vinny.gsd.reminder"
    public static let completeID = "dev.vinny.gsd.reminder.complete"
    public static let snoozeID = "dev.vinny.gsd.reminder.snooze1h"
}

/// Applies a tapped reminder button through `TaskStore`, the single mutation path, so the
/// change is stamped, enqueued for sync, and seen by widgets and Spotlight like any edit.
/// The notification's task may have changed since it was scheduled (completed on another
/// device, saved, deleted), so every action re-reads the persisted row and does nothing
/// when the button no longer applies. `toggleComplete` alone would UNcomplete a task that
/// is already done.
@MainActor
public struct ReminderActionHandler {
    public enum Outcome: Equatable, Sendable { case completed, snoozed, ignored }

    private let store: TaskStore

    public init(store: TaskStore) { self.store = store }

    public func handle(actionIdentifier: String, taskID: String) async throws -> Outcome {
        guard actionIdentifier == ReminderAction.completeID || actionIdentifier == ReminderAction.snoozeID,
              let task = try await store.fetchTask(id: taskID),
              !task.completed, !task.isSaved
        else { return .ignored }

        if actionIdentifier == ReminderAction.completeID {
            try await store.toggleComplete(task)
            return .completed
        }
        try await store.snooze(task, by: .oneHour)
        return .snoozed
    }
}
