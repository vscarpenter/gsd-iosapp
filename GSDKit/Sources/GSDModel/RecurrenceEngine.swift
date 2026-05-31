import Foundation

/// Recurrence date math + instance spawning (product spec §6.5). Pure: the
/// caller injects the `Calendar` (so month-end clamping and time zone are
/// deterministic) and "now" (so spawn timestamps are testable).
public enum RecurrenceEngine {
    /// Advance a due date by one recurrence period. `.none` (no recurrence) and a
    /// `.daily`/`.weekly`/`.monthly` with no due date both return nil — there is
    /// nothing to advance. Monthly uses `Calendar` month arithmetic, which clamps
    /// to the last valid day (Jan 31 + 1mo → Feb 28/29). PROBE-VERIFIED.
    public static func advance(_ dueDate: Date?, by recurrence: RecurrenceType, calendar: Calendar) -> Date? {
        guard let dueDate else { return nil }
        switch recurrence {
        case .none:    return nil
        case .daily:   return calendar.date(byAdding: .day, value: 1, to: dueDate)
        case .weekly:  return calendar.date(byAdding: .day, value: 7, to: dueDate)
        case .monthly: return calendar.date(byAdding: .month, value: 1, to: dueDate)
        }
    }
}

extension RecurrenceEngine {
    /// Spawn the next instance of a recurring task on completion (product spec §6.5).
    /// Returns nil when the task does not recur. The original (completed) task is the
    /// caller's to keep as a historical record; this returns only the NEW instance.
    ///
    /// Single-level lineage: the new instance's `parentTaskId` is the original's
    /// `parentTaskId ?? id` — completing an instance-of-an-instance still points at
    /// the root, never chaining (product spec §9, increment spec §9).
    ///
    /// `subtaskID` regenerates subtask ids so the spawned checklist is independent
    /// of the historical one; injected for test determinism.
    public static func spawnNext(
        from task: Task,
        now: Date,
        newID: String,
        calendar: Calendar,
        subtaskID: () -> String = { IDGenerator.generate(size: IDGenerator.Size.task) }
    ) -> Task? {
        guard task.recurrence != .none else { return nil }
        return Task(
            id: newID,
            title: task.title,
            description: task.description,
            urgent: task.urgent,
            important: task.important,
            completed: false,
            completedAt: nil,
            createdAt: now,
            updatedAt: now,
            dueDate: advance(task.dueDate, by: task.recurrence, calendar: calendar),
            recurrence: task.recurrence,
            tags: task.tags,
            subtasks: task.subtasks.map { Subtask(id: subtaskID(), title: $0.title, completed: false) },
            dependencies: task.dependencies,
            parentTaskId: task.parentTaskId ?? task.id,
            notifyBefore: task.notifyBefore,
            notificationEnabled: task.notificationEnabled,
            notificationSent: false,
            lastNotificationAt: nil,
            snoozedUntil: nil,
            estimatedMinutes: task.estimatedMinutes,
            timeSpent: nil,
            timeEntries: []
        )
    }
}
