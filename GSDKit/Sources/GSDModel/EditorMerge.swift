import Foundation

/// What the editor's Save writes for a task that already exists (parity C10).
///
/// The editor holds three versions of the task: the row it opened, the row the user edited, and
/// the row stored now. For each field the editor owns, the user's value wins only where the user
/// changed it. Every other value comes from the stored row, so a completion, a timer, a snooze, or
/// an edit pulled from another device while the sheet was open survives the save. Android's
/// `EditorRules.merge` applies the same field rule. Android also resets the sent-reminder state
/// when the due date moves, which the iOS scheduler doesn't read, and it doesn't own a separate
/// reminder switch as this editor does.
public enum EditorMerge {
    /// `original` should be `untouched(opened)`, so the editor's tidy-ups don't count as edits.
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
        merged.recurrence = pick(\.recurrence)
        merged.subtasks = pick(\.subtasks)
        merged.dependencies = pick(\.dependencies)
        merged.estimatedMinutes = pick(\.estimatedMinutes)
        merged.snoozedUntil = pick(\.snoozedUntil)
        // The due date and its reminder move as one group. The editor shows the reminder only
        // with a due date and turns it off without one, so a save writes all three or none.
        let reminderGroupChanged = edited.dueDate != original.dueDate
            || edited.notificationEnabled != original.notificationEnabled
            || edited.notifyBefore != original.notifyBefore
        if reminderGroupChanged {
            merged.dueDate = edited.dueDate
            merged.notificationEnabled = edited.notificationEnabled
            merged.notifyBefore = edited.notifyBefore
        }
        return merged
    }

    /// What the editor's Save produces from a task the user didn't change. It trims the title,
    /// shows no reminder without a due date, drops the offset of a reminder that is off, and reads
    /// an estimate of 0 as none. Merging against this, not the raw row, keeps those tidy-ups from
    /// overwriting values synced in while the sheet was open. It must match `TaskEditorView`'s save.
    public static func untouched(_ task: Task) -> Task {
        var tidy = task
        tidy.title = task.title.trimmingCharacters(in: .whitespaces)
        let reminderOn = task.notificationEnabled && task.dueDate != nil
        tidy.notificationEnabled = reminderOn
        tidy.notifyBefore = reminderOn ? task.notifyBefore : nil
        tidy.estimatedMinutes = FieldLimits.normalizedEstimate(task.estimatedMinutes)
        return tidy
    }
}
