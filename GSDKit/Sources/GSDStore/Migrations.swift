import GRDB

extension AppDatabase {
    /// Explicit, versioned migration sequence (increment spec §3.3). Never rely on
    /// auto-migration. `v1` is the full §5.1 `tasks` table; later phases add v2+.
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        registerV1(&migrator)
        registerV2(&migrator)
        registerV3(&migrator)
        registerV4(&migrator)
        registerV5(&migrator)
        return migrator
    }

    static func registerV5(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v5") { db in
            try db.create(table: "syncHistory") { t in
                t.primaryKey("id", .text)
                t.column("timestamp", .integer).notNull().indexed()
                t.column("status", .text).notNull()
                t.column("pushedCount", .integer).notNull().defaults(to: 0)
                t.column("pulledCount", .integer).notNull().defaults(to: 0)
                t.column("conflictsResolved", .integer).notNull().defaults(to: 0)
                t.column("failedCount", .integer)
                t.column("errorMessage", .text)
                t.column("duration", .integer)
                t.column("deviceId", .text).notNull()
                t.column("triggeredBy", .text).notNull()
            }
        }
    }

    static func registerV2(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v2") { db in
            try db.create(table: "smartViews") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("icon", .text).notNull()
                t.column("criteria", .text).notNull()          // FilterCriteria JSON
                t.column("isBuiltIn", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull().indexed()
            }
        }
    }

    static func registerV3(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v3") { db in
            try db.create(table: "archivedTasks") { t in
                t.primaryKey("id", .text)
                t.column("title", .text).notNull()
                t.column("description", .text).notNull().defaults(to: "")
                t.column("urgent", .boolean).notNull()
                t.column("important", .boolean).notNull()
                t.column("quadrant", .text).notNull()
                t.column("completed", .boolean).notNull().defaults(to: false)
                t.column("completedAt", .datetime)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("dueDate", .datetime)
                t.column("recurrence", .text).notNull().defaults(to: "none")
                t.column("tags", .text).notNull().defaults(to: "[]")
                t.column("subtasks", .text).notNull().defaults(to: "[]")
                t.column("dependencies", .text).notNull().defaults(to: "[]")
                t.column("parentTaskId", .text)
                t.column("notifyBefore", .integer)
                t.column("notificationEnabled", .boolean).notNull().defaults(to: true)
                t.column("notificationSent", .boolean).notNull().defaults(to: false)
                t.column("lastNotificationAt", .datetime)
                t.column("snoozedUntil", .datetime)
                t.column("estimatedMinutes", .integer)
                t.column("timeSpent", .integer)
                t.column("timeEntries", .text).notNull().defaults(to: "[]")
                t.column("archivedAt", .datetime).notNull().indexed()
            }
        }
    }

    static func registerV4(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v4") { db in
            try db.create(table: "syncQueue") { t in
                t.primaryKey("id", .text)
                t.column("taskId", .text).notNull().indexed()
                t.column("operation", .text).notNull()
                t.column("timestamp", .integer).notNull().indexed()
                t.column("retryCount", .integer).notNull().defaults(to: 0)
                t.column("payload", .text)                       // JSON-encoded Task; NULL for delete
                t.column("status", .text).notNull().defaults(to: "pending").indexed()
                t.column("lastError", .text)
                t.column("lastAttemptAt", .integer)
                t.column("failedAt", .integer)
            }
        }
    }

    static func registerV1(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v1") { db in
            try db.create(table: "tasks") { t in
                t.primaryKey("id", .text)
                t.column("title", .text).notNull()
                t.column("description", .text).notNull().defaults(to: "")
                t.column("urgent", .boolean).notNull()
                t.column("important", .boolean).notNull()
                t.column("quadrant", .text).notNull().indexed()
                t.column("completed", .boolean).notNull().defaults(to: false).indexed()
                t.column("completedAt", .datetime)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull().indexed()
                t.column("dueDate", .datetime).indexed()
                t.column("recurrence", .text).notNull().defaults(to: "none")
                t.column("tags", .text).notNull().defaults(to: "[]")           // JSON
                t.column("subtasks", .text).notNull().defaults(to: "[]")       // JSON
                t.column("dependencies", .text).notNull().defaults(to: "[]")   // JSON
                t.column("parentTaskId", .text)
                t.column("notifyBefore", .integer)
                t.column("notificationEnabled", .boolean).notNull().defaults(to: true)
                t.column("notificationSent", .boolean).notNull().defaults(to: false)
                t.column("lastNotificationAt", .datetime)
                t.column("snoozedUntil", .datetime)
                t.column("estimatedMinutes", .integer)
                t.column("timeSpent", .integer)
                t.column("timeEntries", .text).notNull().defaults(to: "[]")    // JSON
            }
        }
    }
}
