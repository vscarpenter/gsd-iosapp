import Foundation
import GRDB
import GSDModel

/// GRDB row for a Task. Scalars map directly; embedded collections (`tags`,
/// `subtasks`, `dependencies`, `timeEntries`) are stored as JSON strings to match
/// the web (Dexie) and PocketBase shapes (increment spec §3.3). `quadrant` is
/// persisted (indexed) but always derived from the flags — never set by hand.
struct TaskRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "tasks"

    var id: String
    var title: String
    var description: String
    var urgent: Bool
    var important: Bool
    var quadrant: String
    var completed: Bool
    var completedAt: Date?
    var createdAt: Date
    var updatedAt: Date
    var dueDate: Date?
    var recurrence: String
    var tags: String
    var subtasks: String
    var dependencies: String
    var parentTaskId: String?
    var notifyBefore: Int?
    var notificationEnabled: Bool
    var notificationSent: Bool
    var lastNotificationAt: Date?
    var snoozedUntil: Date?
    var estimatedMinutes: Int?
    var timeSpent: Int?
    var timeEntries: String
}

extension TaskRecord {
    init(_ task: Task) throws {
        id = task.id
        title = task.title
        description = task.description
        urgent = task.urgent
        important = task.important
        quadrant = task.quadrant.rawValue
        completed = task.completed
        completedAt = task.completedAt
        createdAt = task.createdAt
        updatedAt = task.updatedAt
        dueDate = task.dueDate
        recurrence = task.recurrence.rawValue
        tags = try GSDJSON.string(task.tags)
        subtasks = try GSDJSON.string(task.subtasks)
        dependencies = try GSDJSON.string(task.dependencies)
        parentTaskId = task.parentTaskId
        notifyBefore = task.notifyBefore
        notificationEnabled = task.notificationEnabled
        notificationSent = task.notificationSent
        lastNotificationAt = task.lastNotificationAt
        snoozedUntil = task.snoozedUntil
        estimatedMinutes = task.estimatedMinutes
        timeSpent = task.timeSpent
        timeEntries = try GSDJSON.string(task.timeEntries)
    }

    func toDomain() throws -> Task {
        Task(
            id: id, title: title, description: description,
            urgent: urgent, important: important,
            completed: completed, completedAt: completedAt,
            createdAt: createdAt, updatedAt: updatedAt, dueDate: dueDate,
            recurrence: RecurrenceType(rawValue: recurrence) ?? .none,
            tags: try GSDJSON.value([String].self, tags),
            subtasks: try GSDJSON.value([Subtask].self, subtasks),
            dependencies: try GSDJSON.value([String].self, dependencies),
            parentTaskId: parentTaskId,
            notifyBefore: notifyBefore,
            notificationEnabled: notificationEnabled,
            notificationSent: notificationSent,
            lastNotificationAt: lastNotificationAt,
            snoozedUntil: snoozedUntil,
            estimatedMinutes: estimatedMinutes,
            timeSpent: timeSpent,
            timeEntries: try GSDJSON.value([TimeEntry].self, timeEntries)
        )
    }
}
