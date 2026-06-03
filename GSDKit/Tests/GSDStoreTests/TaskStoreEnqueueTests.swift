import Testing
import Foundation
import GSDModel
@testable import GSDStore

@MainActor
struct TaskStoreEnqueueTests {
    final class RecordingQueue: SyncQueueRepository, @unchecked Sendable {
        var ops: [(taskId: String, op: SyncQueueItem.Operation)] = []
        func enqueue(_ item: SyncQueueItem) async throws { ops.append((item.taskId, item.operation)) }
        func pending() async throws -> [SyncQueueItem] { [] }
        func update(_ item: SyncQueueItem) async throws {}
        func remove(id: String) async throws {}
        func allTaskIds() async throws -> Set<String> { [] }
    }
    private func makeStore(_ queue: RecordingQueue) throws -> TaskStore {
        let db = try AppDatabase.inMemory()
        return TaskStore(repository: GRDBTaskRepository(db),
                         smartViewRepository: GRDBSmartViewRepository(db),
                         archiveRepository: GRDBArchiveRepository(db),
                         defaults: UserDefaults(suiteName: "t.\(UUID().uuidString)")!,
                         clock: { Date(timeIntervalSince1970: 1000) },
                         calendar: { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }(),
                         syncQueue: queue)
    }
    private func sample(_ id: String, recurrence: RecurrenceType = .none, due: Date? = nil) -> Task {
        Task(id: id, title: "t", urgent: false, important: false, createdAt: Date(timeIntervalSince1970: 0),
             updatedAt: Date(timeIntervalSince1970: 0), dueDate: due, recurrence: recurrence)
    }

    @Test func addEnqueuesCreate() async throws {   // capture-bar quick-add — a creation path the plan's step-3 list omitted
        let q = RecordingQueue(); let store = try makeStore(q)
        try await store.add(ParsedCapture(title: "Quick", urgent: true, important: false, tags: [], descriptionAdditions: []))
        #expect(q.ops.filter { $0.op == .create }.count == 1)   // enqueued for push (else deletion-reconcile wipes it)
    }

    @Test func createEnqueuesCreate() async throws {
        let q = RecordingQueue(); let store = try makeStore(q)
        try await store.create(sample("a"))
        #expect(q.ops.contains { $0.taskId == "a" && $0.op == .create })
    }

    @Test func saveEnqueuesUpdate() async throws {
        let q = RecordingQueue(); let store = try makeStore(q)
        try await store.save(sample("a"))
        #expect(q.ops.contains { $0.taskId == "a" && $0.op == .update })
    }

    @Test func deleteEnqueuesDelete() async throws {
        let q = RecordingQueue(); let store = try makeStore(q)
        try await store.delete(sample("a"))
        #expect(q.ops.contains { $0.taskId == "a" && $0.op == .delete })
    }

    @Test func toggleCompleteEnqueuesSpawnAsCreate() async throws {
        let q = RecordingQueue(); let store = try makeStore(q)
        let recurring = sample("r", recurrence: .daily, due: Date(timeIntervalSince1970: 500))
        try await store.create(recurring); q.ops.removeAll()
        try await store.toggleComplete(recurring)
        #expect(q.ops.contains { $0.taskId == "r" && $0.op == .update })          // the completed task
        #expect(q.ops.contains { $0.op == .create && $0.taskId != "r" })          // the spawned next instance
    }

    @Test func archiveDoesNotEnqueueButRestoreEnqueuesUpdate() async throws {
        let q = RecordingQueue(); let store = try makeStore(q)
        try await store.create(sample("a")); q.ops.removeAll()
        try await store.archive(sample("a"))
        #expect(q.ops.isEmpty)   // archive is device-local (the archive state never syncs)
        try await store.restore(sample("a"))
        #expect(q.ops.count == 1 && q.ops.contains { $0.taskId == "a" && $0.op == .update })   // restore re-activates → push it
    }
}
