import Testing
import GRDB
@testable import GSDStore

struct MigrationTests {
    @Test func v2CreatesSmartViewsTable() throws {
        let db = try AppDatabase.inMemory()
        try db.writer.read { d in
            #expect(try d.tableExists("smartViews"))
            let columns = Set(try d.columns(in: "smartViews").map(\.name))
            #expect(columns == ["id", "name", "icon", "criteria", "isBuiltIn", "createdAt", "updatedAt"])
        }
    }

    @Test func v2AppliesOverExistingV1DataWithoutLoss() throws {
        // Simulate an existing on-disk DB: run ONLY v1, insert a row, then run the full
        // migrator (v1+v2+v3) and confirm the task survives and smartViews now exists.
        let queue = try DatabaseQueue()
        var v1Only = DatabaseMigrator()
        AppDatabase.registerV1(&v1Only)
        try v1Only.migrate(queue)
        try queue.write { d in
            try d.execute(sql: """
                INSERT INTO tasks (id, title, urgent, important, quadrant, completed, createdAt, updatedAt, recurrence, tags, subtasks, dependencies, notificationEnabled, notificationSent, timeEntries)
                VALUES ('keep', 'Keep me', 0, 0, 'not-urgent-not-important', 0, '1970-01-01T00:00:00.000Z', '1970-01-01T00:00:00.000Z', 'none', '[]', '[]', '[]', 1, 0, '[]')
                """)
        }
        _ = try AppDatabase(queue)   // runs the full migrator over the existing DB
        let hasSmartViews = try queue.read { d in try d.tableExists("smartViews") }
        let keepCount = try queue.read { d in try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM tasks WHERE id = 'keep'") }
        #expect(hasSmartViews)
        #expect(keepCount == 1)
    }

    @Test func v3CreatesArchivedTasksTableWithArchivedAt() throws {
        let db = try AppDatabase.inMemory()
        try db.writer.read { d in
            #expect(try d.tableExists("archivedTasks"))
            let columns = Set(try d.columns(in: "archivedTasks").map(\.name))
            // Same 24 task columns + archivedAt.
            #expect(columns.contains("archivedAt"))
            #expect(columns.contains("id"))
            #expect(columns.contains("completedAt"))
            #expect(columns.count == 25)
            let indexed = Set(try d.indexes(on: "archivedTasks").flatMap(\.columns))
            #expect(indexed.contains("archivedAt"))
        }
    }

    @Test func v1CreatesTasksTableWithFullColumnSet() throws {
        let db = try AppDatabase.inMemory()
        try db.writer.read { d in
            #expect(try d.tableExists("tasks"))
            let columns = Set(try d.columns(in: "tasks").map(\.name))

            // Assert ALL 24 columns from the §5.1 schema are present.
            let expectedColumns: Set<String> = [
                "id",
                "title",
                "description",
                "urgent",
                "important",
                "quadrant",
                "completed",
                "completedAt",
                "createdAt",
                "updatedAt",
                "dueDate",
                "recurrence",
                "tags",
                "subtasks",
                "dependencies",
                "parentTaskId",
                "notifyBefore",
                "notificationEnabled",
                "notificationSent",
                "lastNotificationAt",
                "snoozedUntil",
                "estimatedMinutes",
                "timeSpent",
                "timeEntries",
            ]
            for expected in expectedColumns.sorted() {
                #expect(columns.contains(expected), "missing column: \(expected)")
            }
            #expect(columns == expectedColumns, "unexpected extra columns: \(columns.subtracting(expectedColumns))")

            // Assert the four indexed columns are indexed (product spec §5.1).
            let indexedColumns = Set(try d.indexes(on: "tasks").flatMap(\.columns))
            for col in ["quadrant", "completed", "dueDate", "updatedAt"] {
                #expect(indexedColumns.contains(col), "missing index on column: \(col)")
            }
        }
    }
}
