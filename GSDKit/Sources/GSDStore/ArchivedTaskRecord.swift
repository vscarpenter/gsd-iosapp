import Foundation
import GRDB
import GSDModel

/// GRDB row for an ARCHIVED task — the full §5.1 column set (identical to `tasks`) plus
/// `archivedAt`. Lives in a SEPARATE `archivedTasks` table so archived rows are excluded
/// from the matrix/smart-view queries by construction (design-spec scope call). The
/// task-column mapping is delegated to `TaskRecord` to avoid duplicating 24 fields.
struct ArchivedTaskRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "archivedTasks"

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
    var archivedAt: Date
}

extension ArchivedTaskRecord {
    /// Build from a domain task + the archive timestamp. Reuses `TaskRecord` for the
    /// task-column JSON encoding so the two records stay in lockstep.
    init(_ task: Task, archivedAt: Date) throws {
        let r = try TaskRecord(task)
        id = r.id; title = r.title; description = r.description
        urgent = r.urgent; important = r.important; quadrant = r.quadrant
        completed = r.completed; completedAt = r.completedAt
        createdAt = r.createdAt; updatedAt = r.updatedAt; dueDate = r.dueDate
        recurrence = r.recurrence; tags = r.tags; subtasks = r.subtasks
        dependencies = r.dependencies; parentTaskId = r.parentTaskId
        notifyBefore = r.notifyBefore; notificationEnabled = r.notificationEnabled
        notificationSent = r.notificationSent; lastNotificationAt = r.lastNotificationAt
        snoozedUntil = r.snoozedUntil; estimatedMinutes = r.estimatedMinutes
        timeSpent = r.timeSpent; timeEntries = r.timeEntries
        self.archivedAt = archivedAt
    }

    /// Reconstruct the domain task (drops `archivedAt`, which is archive-only metadata).
    func toDomain() throws -> Task {
        let r = TaskRecord(id: id, title: title, description: description, urgent: urgent,
                           important: important, quadrant: quadrant, completed: completed,
                           completedAt: completedAt, createdAt: createdAt, updatedAt: updatedAt,
                           dueDate: dueDate, recurrence: recurrence, tags: tags, subtasks: subtasks,
                           dependencies: dependencies, parentTaskId: parentTaskId,
                           notifyBefore: notifyBefore, notificationEnabled: notificationEnabled,
                           notificationSent: notificationSent, lastNotificationAt: lastNotificationAt,
                           snoozedUntil: snoozedUntil, estimatedMinutes: estimatedMinutes,
                           timeSpent: timeSpent, timeEntries: timeEntries)
        return try r.toDomain()
    }
}
