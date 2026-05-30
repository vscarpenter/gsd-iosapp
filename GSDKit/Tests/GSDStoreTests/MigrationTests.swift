import Testing
import GRDB
@testable import GSDStore

struct MigrationTests {
    @Test func v1CreatesTasksTableWithFullColumnSet() throws {
        let db = try AppDatabase.inMemory()
        try db.writer.read { d in
            #expect(try d.tableExists("tasks"))
            let columns = Set(try d.columns(in: "tasks").map(\.name))
            // spot-check the spec-critical columns across scalar, JSON, and device-local groups
            for expected in ["id", "quadrant", "tags", "subtasks", "dependencies",
                             "timeEntries", "snoozedUntil", "notificationSent", "updatedAt"] {
                #expect(columns.contains(expected), "missing column \(expected)")
            }
        }
    }
}
