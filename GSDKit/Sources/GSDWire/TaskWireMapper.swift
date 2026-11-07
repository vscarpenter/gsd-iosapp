import Foundation
import GSDModel

/// Bidirectional mapper between the local `Task` (camelCase, rich `timeEntries`) and the PocketBase
/// wire record (snake_case, flattened `time_entries`) — product spec §7.2. Pure: `owner`/`deviceId`/
/// `recordId` are parameters (the 5c push engine supplies them); no I/O, no identity lookup.
package enum TaskWireMapper {

    // MARK: Local → Wire (push)

    package static func toWire(_ task: Task, owner: String, deviceId: String, recordId: String = "") -> PocketBaseTaskRecord {
        PocketBaseTaskRecord(
            id: recordId,
            taskId: task.id,
            owner: owner,
            title: task.title,
            description: task.description,
            urgent: task.urgent,
            important: task.important,
            quadrant: task.quadrant.rawValue,
            dueDate: WireDate.format(task.dueDate),
            completed: task.completed,
            completedAt: WireDate.format(task.completedAt),
            recurrence: task.recurrence.rawValue,
            tags: task.tags,
            subtasks: task.subtasks,
            dependencies: task.dependencies,
            notificationEnabled: task.notificationEnabled,
            notificationSent: task.notificationSent,
            notifyBefore: task.notifyBefore,
            lastNotificationAt: WireDate.format(task.lastNotificationAt),
            estimatedMinutes: task.estimatedMinutes,
            timeSpent: task.timeSpent ?? 0,
            timeEntries: task.timeEntries.map(flatten),
            snoozedUntil: WireDate.format(task.snoozedUntil),
            clientUpdatedAt: WireDate.format(task.updatedAt),
            clientCreatedAt: WireDate.format(task.createdAt),
            deviceId: deviceId,
            savedAt: WireDate.format(task.savedAt)
        )
    }

    private static func flatten(_ entry: TimeEntry) -> WireTimeEntry {
        let minutes: Int
        if let ended = entry.endedAt {
            minutes = max(0, Int((ended.timeIntervalSince(entry.startedAt) / 60).rounded(.down)))
        } else {
            minutes = 0   // still-running entry
        }
        return WireTimeEntry(id: entry.id, startedAt: WireDate.format(entry.startedAt), minutes: minutes)
    }

    // MARK: Wire → Local (pull)

    /// `local == nil` → reconstruct best-effort; `local != nil` → merge (remote wins for synced
    /// fields, device-local + derived fields preserved from `local`). `quadrant` is always recomputed.
    package static func toDomain(_ record: PocketBaseTaskRecord, mergingInto local: Task?) -> Task {
        guard let local else { return reconstructed(from: record) }
        return merged(record, into: local)
    }

    /// New-from-remote: reconstruct. No local lineage; device-local fields come from the wire.
    private static func reconstructed(from r: PocketBaseTaskRecord) -> Task {
        Task(
            id: r.taskId, title: r.title, description: r.description,
            urgent: r.urgent, important: r.important,
            completed: r.completed, completedAt: WireDate.parse(r.completedAt),
            createdAt: WireDate.parse(r.clientCreatedAt) ?? Date(timeIntervalSince1970: 0),
            updatedAt: WireDate.parse(r.clientUpdatedAt) ?? Date(timeIntervalSince1970: 0),
            dueDate: WireDate.parse(r.dueDate),
            recurrence: RecurrenceType(rawValue: r.recurrence) ?? .none,
            tags: r.tags, subtasks: r.subtasks, dependencies: r.dependencies,
            parentTaskId: nil,                              // §7.1 has no wire column
            notifyBefore: r.notifyBefore,
            notificationEnabled: r.notificationEnabled,
            notificationSent: r.notificationSent,
            lastNotificationAt: WireDate.parse(r.lastNotificationAt),
            snoozedUntil: WireDate.parse(r.snoozedUntil),
            estimatedMinutes: r.estimatedMinutes,
            timeSpent: r.timeSpent,
            timeEntries: r.timeEntries.map(reconstruct),
            savedAt: WireDate.parse(r.savedAt)
        )
    }

    /// Pull-merge into an existing local task: remote wins for synced fields; the device-local +
    /// derived set is preserved from `local` (conventions 7). This device's reminder state stays
    /// local unless the pull returns the task from Saved or moves its due date to another instant.
    /// Either one is a new reminder, as the native edit makes it, and the old state would hide it
    /// (B-55; web `localReminderState`, Android `reminderSource`). `quadrant` recomputed from flags.
    private static func merged(_ r: PocketBaseTaskRecord, into local: Task) -> Task {
        let savedAt = WireDate.parse(r.savedAt)
        let returning = local.isSaved && savedAt == nil
        let dueDate = WireDate.parse(r.dueDate)
        let keepsReminder = !returning && isSameInstant(local.dueDate, dueDate)
        return Task(
            id: r.taskId, title: r.title, description: r.description,
            urgent: r.urgent, important: r.important,
            completed: r.completed, completedAt: WireDate.parse(r.completedAt),
            createdAt: WireDate.parse(r.clientCreatedAt) ?? local.createdAt,
            updatedAt: WireDate.parse(r.clientUpdatedAt) ?? local.updatedAt,
            dueDate: dueDate,
            recurrence: RecurrenceType(rawValue: r.recurrence) ?? .none,
            tags: r.tags, subtasks: r.subtasks, dependencies: r.dependencies,
            parentTaskId: local.parentTaskId,               // device-local (no wire column)
            notifyBefore: r.notifyBefore,
            notificationEnabled: r.notificationEnabled,
            notificationSent: keepsReminder ? local.notificationSent : false,
            lastNotificationAt: keepsReminder ? local.lastNotificationAt : nil,
            snoozedUntil: keepsReminder ? local.snoozedUntil : nil,
            estimatedMinutes: r.estimatedMinutes,
            timeSpent: local.timeSpent,                     // derived from timeEntries → stays local
            timeEntries: local.timeEntries,                 // wire form lossy → prefer local
            savedAt: savedAt
        )
    }

    /// Equal to the millisecond, the precision web and Android compare at. Both nil counts as equal.
    private static func isSameInstant(_ a: Date?, _ b: Date?) -> Bool { a.map(epochMs) == b.map(epochMs) }

    private static func epochMs(_ date: Date) -> Int { Int((date.timeIntervalSince1970 * 1000).rounded()) }

    private static func reconstruct(_ wire: WireTimeEntry) -> TimeEntry {
        let started = WireDate.parse(wire.startedAt) ?? Date(timeIntervalSince1970: 0)
        return TimeEntry(id: wire.id, startedAt: started,
                         endedAt: started.addingTimeInterval(Double(wire.minutes) * 60), notes: nil)
    }
}
