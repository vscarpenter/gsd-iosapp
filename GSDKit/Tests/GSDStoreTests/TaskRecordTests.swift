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

    /// Proves that sub-second (millisecond-aligned) dates in embedded collections
    /// survive the TaskRecord round-trip. This exposes the ISO-8601 truncation bug
    /// where .iso8601 encoding drops fractional seconds (1500.5 → 1500.0).
    @Test func roundTripsSubSecondMillisecondDates() throws {
        let task = Task(
            id: "rt2", title: "Sub-second test", description: "",
            urgent: false, important: true,
            completed: false, completedAt: nil,
            createdAt: Date(timeIntervalSince1970: 1000),
            updatedAt: Date(timeIntervalSince1970: 2000.5),
            dueDate: nil,
            recurrence: .none,
            tags: [],
            subtasks: [],
            dependencies: [],
            timeEntries: [
                TimeEntry(id: "te000002",
                          startedAt: Date(timeIntervalSince1970: 1500.5),
                          endedAt: Date(timeIntervalSince1970: 1800.25),
                          notes: "x")
            ]
        )
        let restored = try TaskRecord(task).toDomain()
        #expect(restored == task)
    }
}
