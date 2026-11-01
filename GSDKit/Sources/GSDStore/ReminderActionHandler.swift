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
    private let isBackgrounded: @MainActor () -> Bool
    private let resumeDatabase: @MainActor () -> Void
    private let suspendDatabase: @MainActor () -> Void

    public init(store: TaskStore,
                isBackgrounded: @escaping @MainActor () -> Bool = { false },
                resumeDatabase: @escaping @MainActor () -> Void = AppDatabase.resume,
                suspendDatabase: @escaping @MainActor () -> Void = AppDatabase.suspend) {
        self.store = store
        self.isBackgrounded = isBackgrounded
        self.resumeDatabase = resumeDatabase
        self.suspendDatabase = suspendDatabase
    }

    public func handle(actionIdentifier: String, taskID: String) async throws -> Outcome {
        guard actionIdentifier == ReminderAction.completeID || actionIdentifier == ReminderAction.snoozeID else {
            return .ignored
        }
        // A fired reminder usually reaches a suspended app, and a suspended database rejects every
        // read and write. Close it again unless the app came forward, which needs it live.
        let backgrounded = isBackgrounded()
        if backgrounded { resumeDatabase() }
        defer { if backgrounded && isBackgrounded() { suspendDatabase() } }

        guard let task = try await store.fetchTask(id: taskID), !task.completed, !task.isSaved else {
            return .ignored
        }
        if actionIdentifier == ReminderAction.completeID {
            try await store.toggleComplete(task)
            return .completed
        }
        try await store.snooze(task, by: .oneHour)
        return .snoozed
    }
}
