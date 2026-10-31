import Testing
import Foundation
import GSDModel
@testable import GSDStore

/// B-47. An archive's queued delete carries the task as archived, so push can tell whether the server
/// copy moved on since. Trash and import replace carry nothing, and get only the B-42 check.
@MainActor
struct TaskStoreDeletePayloadTests {
    private let now = Date(timeIntervalSince1970: 1_781_510_400)

    private func make() throws -> (TaskStore, GRDBSyncQueueRepository) {
        let db = try AppDatabase.inMemory(); let queue = GRDBSyncQueueRepository(db); let fixed = now
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let store = TaskStore(repository: GRDBTaskRepository(db, now: { fixed }),
                              smartViewRepository: GRDBSmartViewRepository(db),
                              archiveRepository: GRDBArchiveRepository(db, now: { fixed }),
                              trashRepository: GRDBTrashRepository(db, now: { fixed }),
                              defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!,
                              clock: { fixed }, newID: { "id" }, calendar: cal, syncQueue: queue)
        return (store, queue)
    }
    private func task(_ id: String = "a", title: String = "as archived") -> Task {
        Task(id: id, title: title, urgent: false, important: false, createdAt: now, updatedAt: now)
    }
    private func deleteRows(_ queue: GRDBSyncQueueRepository) async throws -> [SyncQueueItem] {
        try await queue.all().filter { $0.operation == .delete }
    }

    @Test func anArchiveQueuesADeleteCarryingTheTask() async throws {
        let (store, queue) = try make()
        try await store.create(task())
        try await store.archive(task())
        let rows = try await deleteRows(queue)
        #expect(rows.map(\.taskId) == ["a"])
        #expect(rows.first?.payload?.title == "as archived")
        #expect(rows.first?.payload?.updatedAt == now)
    }

    @Test func trashQueuesADeleteWithNoPayload() async throws {
        let (store, queue) = try make()
        try await store.create(task())
        try await store.delete(task())
        let rows = try await deleteRows(queue)
        #expect(rows.map(\.taskId) == ["a"])
        #expect(rows.first?.payload == nil)
    }

    @Test func importReplaceQueuesDeletesWithNoPayload() async throws {
        let backup = try TaskExport.encode(TaskExport(tasks: [task("kept")], exportedAt: now))
        let (store, queue) = try make()
        try await store.create(task("removed"))
        try await store.importTasks(backup, mode: .replace)
        let rows = try await deleteRows(queue)
        #expect(rows.map(\.taskId) == ["removed"])
        #expect(rows.first?.payload == nil)
    }
}
