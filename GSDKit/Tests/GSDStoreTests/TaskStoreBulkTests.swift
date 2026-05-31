import Testing
import Foundation
import GSDModel
@testable import GSDStore

@MainActor
struct TaskStoreBulkTests {
    private let now = Date(timeIntervalSince1970: 10_000)
    private func makeStore() throws -> TaskStore {
        let db = try AppDatabase.inMemory()
        return TaskStore(repository: GRDBTaskRepository(db, now: { Date(timeIntervalSince1970: 0) }),
                         smartViewRepository: GRDBSmartViewRepository(db),
                         archiveRepository: GRDBArchiveRepository(db, now: { Date(timeIntervalSince1970: 0) }),
                         defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!,
                         clock: { self.now }, newID: { "id" }, calendar: .current)
    }
    private func task(_ id: String, tags: [String] = []) -> Task {
        Task(id: id, title: id, urgent: false, important: false,
             createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0), tags: tags)
    }
    private func seed(_ store: TaskStore, _ tasks: [Task]) async throws {
        for t in tasks { try await store.create(t) }
        store.start(); var w = 0
        while store.tasks.count != tasks.count && w < 100 { try await _Concurrency.Task.sleep(for: .milliseconds(10)); w += 1 }
    }

    @Test func bulkCompleteMarksAllComplete() async throws {
        let store = try makeStore()
        try await seed(store, [task("a"), task("b"), task("c")])
        try await store.bulkComplete(ids: ["a", "b"])
        var w = 0
        while store.tasks.filter({ $0.completed }).count != 2 && w < 100 { try await _Concurrency.Task.sleep(for: .milliseconds(10)); w += 1 }
        #expect(Set(store.tasks.filter { $0.completed }.map(\.id)) == ["a", "b"])
    }
    @Test func bulkMoveSetsQuadrant() async throws {
        let store = try makeStore()
        try await seed(store, [task("a"), task("b")])
        try await store.bulkMove(ids: ["a", "b"], to: .urgentImportant)
        var w = 0
        while store.tasks.filter({ $0.quadrant == .urgentImportant }).count != 2 && w < 100 { try await _Concurrency.Task.sleep(for: .milliseconds(10)); w += 1 }
        #expect(store.tasks.allSatisfy { $0.quadrant == .urgentImportant })
    }
    @Test func bulkAddAndRemoveTags() async throws {
        let store = try makeStore()
        try await seed(store, [task("a"), task("b", tags: ["keep"])])
        try await store.bulkAddTags(ids: ["a", "b"], tags: ["focus"])
        var w = 0
        while !(store.tasks.first { $0.id == "a" }?.tags.contains("focus") ?? false) && w < 100 { try await _Concurrency.Task.sleep(for: .milliseconds(10)); w += 1 }
        #expect(store.tasks.first { $0.id == "b" }?.tags.sorted() == ["focus", "keep"])
        try await store.bulkRemoveTags(ids: ["a", "b"], tags: ["focus"])
        w = 0
        while (store.tasks.first { $0.id == "a" }?.tags.contains("focus") ?? true) && w < 100 { try await _Concurrency.Task.sleep(for: .milliseconds(10)); w += 1 }
        #expect(store.tasks.first { $0.id == "a" }?.tags.isEmpty == true)
        #expect(store.tasks.first { $0.id == "b" }?.tags == ["keep"])
    }
    @Test func bulkSetDueStampsDueDate() async throws {
        let store = try makeStore()
        try await seed(store, [task("a"), task("b")])
        let due = Date(timeIntervalSince1970: 999_999)
        try await store.bulkSetDue(ids: ["a", "b"], to: due)
        var w = 0
        while (store.tasks.first { $0.id == "a" }?.dueDate == nil) && w < 100 { try await _Concurrency.Task.sleep(for: .milliseconds(10)); w += 1 }
        #expect(store.tasks.allSatisfy { $0.dueDate == due })
    }
    @Test func bulkDeleteRemovesTasks() async throws {
        let store = try makeStore()
        try await seed(store, [task("a"), task("b"), task("c")])
        try await store.bulkDelete(ids: ["a", "b"])
        var w = 0
        while store.tasks.count != 1 && w < 100 { try await _Concurrency.Task.sleep(for: .milliseconds(10)); w += 1 }
        #expect(store.tasks.map(\.id) == ["c"])
    }
    @Test func bulkAddTagsSkipsTaskThatWouldExceedTagLimit() async throws {
        // Validation is per-task: a task already at maxTags is left unchanged, the batch continues.
        let store = try makeStore()
        let full = task("full", tags: (0..<FieldLimits.maxTags).map { "t\($0)" })
        try await seed(store, [full, task("ok")])
        try await store.bulkAddTags(ids: ["full", "ok"], tags: ["new"])
        var w = 0
        while !(store.tasks.first { $0.id == "ok" }?.tags.contains("new") ?? false) && w < 100 { try await _Concurrency.Task.sleep(for: .milliseconds(10)); w += 1 }
        #expect(store.tasks.first { $0.id == "ok" }?.tags.contains("new") == true)
        #expect(store.tasks.first { $0.id == "full" }?.tags.count == FieldLimits.maxTags)  // unchanged
    }
}
