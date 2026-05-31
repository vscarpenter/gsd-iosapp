import Testing
import Foundation
@testable import GSDModel

struct TaskImporterTests {
    private func task(_ id: String, deps: [String] = [], parent: String? = nil) -> Task {
        Task(id: id, title: id, urgent: false, important: false,
             createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0),
             dependencies: deps, parentTaskId: parent)
    }
    private func data(_ tasks: [Task]) throws -> Data {
        try TaskExport.encode(TaskExport(tasks: tasks, exportedAt: Date(timeIntervalSince1970: 0)))
    }
    private func counter(_ prefix: String) -> () -> String {
        var n = 0; return { n += 1; return "\(prefix)\(n)" }
    }

    // MARK: replace
    @Test func replaceReturnsAllTasksUnchanged() throws {
        let result = try TaskImporter.replace(from: try data([task("a"), task("b")]))
        #expect(result.tasks.map(\.id) == ["a", "b"])
        #expect(result.skipped == 0)
    }

    // MARK: merge id-remap (two-phase)
    @Test func mergeRegeneratesCollidingIdAndRemapsForwardDependency() throws {
        // B listed before A; B depends on A; A collides with an existing id.
        let bytes = try data([task("B", deps: ["A"]), task("A")])
        let result = try TaskImporter.merge(from: bytes, existingIDs: ["A"], newID: counter("new-"))
        let a = result.tasks.first { $0.dependencies.isEmpty }!
        let b = result.tasks.first { $0.id == "B" }!
        #expect(a.id == "new-1")                  // A regenerated
        #expect(b.dependencies == ["new-1"])      // B's forward dep remapped
    }
    @Test func mergeRemapsParentTaskId() throws {
        let bytes = try data([task("child", parent: "parent"), task("parent")])
        let result = try TaskImporter.merge(from: bytes, existingIDs: ["parent"], newID: counter("g-"))
        let child = result.tasks.first { $0.id == "child" }!
        #expect(result.tasks.contains { $0.id == "g-1" })
        #expect(child.parentTaskId == "g-1")
    }
    @Test func mergeLeavesNonCollidingAndDanglingRefsUntouched() throws {
        let bytes = try data([task("x", deps: ["ghost"], parent: "z")])
        let result = try TaskImporter.merge(from: bytes, existingIDs: ["other"], newID: counter("n-"))
        #expect(result.tasks[0].id == "x")
        #expect(result.tasks[0].dependencies == ["ghost"])   // dangling ref preserved
        #expect(result.tasks[0].parentTaskId == "z")
    }

    // MARK: lenient decode
    @Test func lenientDecodeIgnoresUnknownKeysAndFillsMissing() throws {
        // A hand-rolled envelope: one task with ONLY the 6 required keys (every defaulted
        // field omitted) + a legacy `vectorClock` key — decodes via C0's lenient init; one
        // task structurally broken (title is a number) — skipped + counted.
        let json = """
        {"version":1,"exportedAt":"1970-01-01T00:00:00.000Z","tasks":[
          {"id":"ok","title":"Legacy","urgent":true,"important":false,
           "createdAt":"1970-01-01T00:00:00.000Z","updatedAt":"1970-01-01T00:00:00.000Z",
           "vectorClock":{"node":5}},
          {"id":"bad","title":42,"urgent":true,"important":true,
           "createdAt":"1970-01-01T00:00:00.000Z","updatedAt":"1970-01-01T00:00:00.000Z"}
        ]}
        """
        let result = try TaskImporter.replace(from: Data(json.utf8))
        #expect(result.tasks.map(\.id) == ["ok"])   // bad task skipped
        #expect(result.skipped == 1)
        #expect(result.tasks.first?.urgent == true)  // decoded fields preserved
        #expect(result.tasks.first?.tags == [])      // missing key → default
    }

    // MARK: limits
    @Test func tooManyTasksThrows() throws {
        let many = (0..<(TaskImporter.maxImportTasks + 1)).map { task("t\($0)") }
        #expect(throws: ImportError.self) { _ = try TaskImporter.replace(from: try data(many)) }
    }
    @Test func oversizedPayloadThrows() throws {
        let big = Data(count: TaskImporter.maxImportBytes + 1)
        #expect(throws: ImportError.self) { _ = try TaskImporter.replace(from: big) }
    }
    @Test func malformedEnvelopeThrows() throws {
        #expect(throws: ImportError.self) { _ = try TaskImporter.replace(from: Data("not json".utf8)) }
    }
}
