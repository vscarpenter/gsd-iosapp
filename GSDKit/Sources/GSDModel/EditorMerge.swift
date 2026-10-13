import Foundation

/// What the editor's Save writes for a task that already exists (parity C10).
///
/// The editor holds three versions of the task: the row it opened, the row the user edited, and
/// the row stored now. For each field the editor owns, the user's value wins only where the user
/// changed it. Every other value comes from the stored row, so a completion, a timer, a snooze, or
/// an edit pulled from another device while the sheet was open survives the save. Android's
/// `EditorRules.merge` follows the same rule.
public enum EditorMerge {
    public static func merge(current: Task, original: Task, edited: Task) -> Task {
        func pick<Value: Equatable>(_ field: KeyPath<Task, Value>) -> Value {
            edited[keyPath: field] != original[keyPath: field] ? edited[keyPath: field] : current[keyPath: field]
        }
        var merged = current
        merged.title = pick(\.title)
        merged.description = pick(\.description)
        merged.urgent = pick(\.urgent)
        merged.important = pick(\.important)
        merged.tags = pick(\.tags)
        merged.dueDate = pick(\.dueDate)
        merged.recurrence = pick(\.recurrence)
        merged.subtasks = pick(\.subtasks)
        merged.dependencies = pick(\.dependencies)
        merged.notificationEnabled = pick(\.notificationEnabled)
        merged.notifyBefore = pick(\.notifyBefore)
        merged.estimatedMinutes = pick(\.estimatedMinutes)
        merged.snoozedUntil = pick(\.snoozedUntil)
        return merged
    }
}
