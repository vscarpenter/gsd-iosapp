import Testing
import Foundation
@testable import GSDModel

struct TaskTests {
    @Test func quadrantIsDerivedFromFlagsAndNeverStoredDirectly() {
        var task = Task(id: "t1", title: "Ship", urgent: true, important: true,
                        createdAt: Date(timeIntervalSince1970: 0),
                        updatedAt: Date(timeIntervalSince1970: 0))
        #expect(task.quadrant == .urgentImportant)
        task.urgent = false
        #expect(task.quadrant == .notUrgentImportant) // recomputed, no drift
    }

    @Test func defaultsMatchSpec() {
        let task = Task(id: "t2", title: "Read", urgent: false, important: false,
                        createdAt: Date(timeIntervalSince1970: 0),
                        updatedAt: Date(timeIntervalSince1970: 0))
        #expect(task.completed == false)
        #expect(task.recurrence == .none)
        #expect(task.tags.isEmpty)
        #expect(task.subtasks.isEmpty)
        #expect(task.dependencies.isEmpty)
        #expect(task.notificationEnabled == true)
        #expect(task.notificationSent == false)
        #expect(task.timeEntries.isEmpty)
    }

    @Test func encodesAndDecodesRoundTrip() throws {
        let task = Task(id: "t3", title: "Plan", urgent: false, important: true,
                        createdAt: Date(timeIntervalSince1970: 100),
                        updatedAt: Date(timeIntervalSince1970: 200),
                        tags: ["home"], dependencies: ["t1"])
        let data = try JSONEncoder().encode(task)
        let decoded = try JSONDecoder().decode(Task.self, from: data)
        #expect(decoded == task)
    }
}
