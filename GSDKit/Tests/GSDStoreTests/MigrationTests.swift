import Testing
import GRDB
@testable import GSDStore

struct MigrationTests {
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
