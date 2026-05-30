import Testing
import Foundation
import GSDModel
@testable import GSDStore

struct TaskRecordTests {
    @Test func roundTripsToDomainIdentity() throws {
        let task = Task(
            id: "rt1", title: "Plan trip", description: "book flights",
            urgent: true, important: true,
            completed: false, completedAt: nil,
            createdAt: Date(timeIntervalSince1970: 1000),
            updatedAt: Date(timeIntervalSince1970: 2000),
            dueDate: Date(timeIntervalSince1970: 3000),
            recurrence: .weekly,
            tags: ["travel", "home"],
            subtasks: [Subtask(id: "s001", title: "passport", completed: true)],
            dependencies: ["dep1", "dep2"],
            estimatedMinutes: 60,
            timeEntries: [TimeEntry(id: "te000001", startedAt: Date(timeIntervalSince1970: 1500),
                                    endedAt: Date(timeIntervalSince1970: 1800), notes: "focus")]
        )
        let record = try TaskRecord(task)
        #expect(record.quadrant == "urgent-important")
        let restored = try record.toDomain()
        #expect(restored == task)
    }
}
