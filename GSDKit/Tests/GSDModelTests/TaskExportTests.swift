import Testing
import Foundation
@testable import GSDModel

struct TaskExportTests {
    private func task(_ id: String, due: Date? = nil) -> Task {
        Task(id: id, title: id, urgent: true, important: true,
             createdAt: Date(timeIntervalSince1970: 1_700_000_000),
             updatedAt: Date(timeIntervalSince1970: 1_700_000_000), dueDate: due)
    }

    @Test func envelopeShapeHasTasksExportedAtVersion() throws {
        let export = TaskExport(tasks: [task("a")], exportedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let json = String(decoding: try TaskExport.encode(export), as: UTF8.self)
        #expect(json.contains("\"tasks\""))
        #expect(json.contains("\"exportedAt\""))
        #expect(json.contains("\"version\""))
    }
    @Test func versionDefaultsToOne() {
        #expect(TaskExport(tasks: [], exportedAt: Date()).version == 1)
    }
    @Test func roundTripsPreservingTasks() throws {
        let original = TaskExport(tasks: [task("a", due: Date(timeIntervalSince1970: 1_700_600_000)), task("b")],
                                  exportedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let decoded = try TaskExport.decode(try TaskExport.encode(original))
        #expect(decoded.tasks.map(\.id) == ["a", "b"])
        #expect(decoded.tasks.first?.dueDate == original.tasks.first?.dueDate)
        #expect(decoded.version == 1)
    }
    @Test func datesUseFractionalSecondsISO8601() throws {
        // 500ms past the epoch-aligned second → fractional-seconds component must survive.
        let t = Task(id: "x", title: "x", urgent: false, important: false,
                     createdAt: Date(timeIntervalSince1970: 0.5),
                     updatedAt: Date(timeIntervalSince1970: 0.5))
        let json = String(decoding: try TaskExport.encode(TaskExport(tasks: [t], exportedAt: Date(timeIntervalSince1970: 0.5))), as: UTF8.self)
        #expect(json.contains(".500Z"))
    }
}
