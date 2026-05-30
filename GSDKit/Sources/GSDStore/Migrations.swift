import GRDB

extension AppDatabase {
    /// Explicit, versioned migration sequence (increment spec §3.3). Never rely on
    /// auto-migration. `v1` is the full §5.1 `tasks` table; later phases add v2+.
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        registerV1(&migrator)
        return migrator
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
