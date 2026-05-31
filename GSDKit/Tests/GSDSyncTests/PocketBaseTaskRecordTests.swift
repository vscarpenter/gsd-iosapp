import Testing
import Foundation
import GSDModel
@testable import GSDSync

struct PocketBaseTaskRecordTests {
    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }
    private func decode(_ name: String) throws -> PocketBaseTaskRecord {
        try JSONDecoder().decode(PocketBaseTaskRecord.self, from: fixture(name))
    }

    @Test func decodesWellFormedRecord() throws {
        let r = try decode("task_well_formed")
        #expect(r.id == "rec_abc123")          // PocketBase record id
        #expect(r.taskId == "task-1")          // join key — distinct from record id
        #expect(r.title == "Ship sync")
        #expect(r.tags == ["work", "sync"])
        #expect(r.subtasks == [Subtask(id: "sub1", title: "design", completed: true)])
        #expect(r.dependencies == ["task-0"])
        #expect(r.notifyBefore == 30)
        #expect(r.timeEntries == [WireTimeEntry(id: "te1", startedAt: "2026-06-15T08:00:00.000Z", minutes: 5)])
        #expect(r.clientUpdatedAt == "2026-06-15T08:30:00.500Z")
    }

    @Test func emptyDatesAndNullNumbersDecode() throws {
        let r = try decode("task_empty_dates")
        #expect(r.dueDate == "")
        #expect(WireDate.parse(r.dueDate) == nil)
        #expect(r.notifyBefore == nil)         // JSON null → nil
        #expect(r.estimatedMinutes == nil)
        #expect(r.timeSpent == 0)
    }

    @Test func missingOptionalFieldsDefaultWithoutThrowing() throws {
        let r = try decode("task_missing_fields")   // only task_id/title/urgent/important present
        #expect(r.taskId == "task-3")
        #expect(r.description == "")
        #expect(r.recurrence == "none")
        #expect(r.tags == [])
        #expect(r.notificationEnabled == true)       // §5.1 default
        #expect(r.notifyBefore == nil)
        #expect(r.dueDate == "")                     // key-absent non-optional → defaulted
    }

    @Test func recordMissingTaskIdFailsToDecode() {
        let json = Data(#"{"title":"x","urgent":false,"important":false}"#.utf8)
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(PocketBaseTaskRecord.self, from: json)
        }
    }

    @Test func decodeListSkipsMalformedRecords() throws {
        let records = try PocketBaseTaskRecord.decodeList(fixture("task_list_with_malformed"))
        #expect(records.count == 2)                  // the middle (no task_id) is skipped, not fatal
        #expect(records.map(\.taskId) == ["task-ok-1", "task-ok-2"])
    }
}
