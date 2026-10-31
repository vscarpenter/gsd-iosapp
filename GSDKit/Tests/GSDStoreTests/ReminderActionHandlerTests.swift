import Testing
import Foundation
import GSDModel
@testable import GSDStore

/// B-17: the Complete and Snooze 1h buttons on a reminder notification. The handler is the
/// device-free core; the App's `UNUserNotificationCenterDelegate` only forwards to it.
@MainActor
struct ReminderActionHandlerTests {
    final class RecordingQueue: SyncQueueRepository, @unchecked Sendable {
        var ops: [(taskId: String, op: SyncQueueItem.Operation)] = []
        func enqueue(_ item: SyncQueueItem) async throws { ops.append((item.taskId, item.operation)) }
        func pending() async throws -> [SyncQueueItem] { [] }
        func update(_ item: SyncQueueItem) async throws {}
        func remove(id: String) async throws {}
        func allTaskIds() async throws -> Set<String> { [] }
        func all() async throws -> [SyncQueueItem] { [] }
    }

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeStore(_ queue: RecordingQueue) throws -> TaskStore {
        let db = try AppDatabase.inMemory()
        let now = self.now
        return TaskStore(repository: GRDBTaskRepository(db),
                         smartViewRepository: GRDBSmartViewRepository(db),
                         archiveRepository: GRDBArchiveRepository(db),
                         trashRepository: GRDBTrashRepository(db),
                         defaults: UserDefaults(suiteName: "t.\(UUID().uuidString)")!,
                         clock: { now },
                         syncQueue: queue)
    }

    private func seed(_ store: TaskStore, id: String = "t1", completed: Bool = false, saved: Bool = false) async throws {
        var task = Task(id: id, title: "Pay rent", urgent: false, important: true,
                        createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0),
                        dueDate: now.addingTimeInterval(3600))
        task.completed = completed
        if saved { task.savedAt = now }
        try await store.ingestSynced(task)
    }

    @Test func completeMarksTheTaskDoneAndEnqueuesAnUpdate() async throws {
        let q = RecordingQueue(); let store = try makeStore(q)
        try await seed(store)
        var mutations = 0
        store.onMutation = { mutations += 1 }

        let outcome = try await ReminderActionHandler(store: store)
            .handle(actionIdentifier: ReminderAction.completeID, taskID: "t1")

        #expect(outcome == .completed)
        #expect(try await store.fetchTask(id: "t1")?.completed == true)
        #expect(q.ops.map(\.op) == [.update])     // sync gets the change
        #expect(mutations >= 1)                    // widgets and the debounced push hang off this
    }

    @Test func completeOnAnAlreadyCompletedTaskDoesNotUncompleteIt() async throws {
        let q = RecordingQueue(); let store = try makeStore(q)
        try await seed(store, completed: true)

        let outcome = try await ReminderActionHandler(store: store)
            .handle(actionIdentifier: ReminderAction.completeID, taskID: "t1")

        #expect(outcome == .ignored)
        #expect(try await store.fetchTask(id: "t1")?.completed == true)   // toggleComplete alone would flip it back
        #expect(q.ops.isEmpty)
    }

    @Test func snoozeOneHourSetsSnoozedUntilAndEnqueuesAnUpdate() async throws {
        let q = RecordingQueue(); let store = try makeStore(q)
        try await seed(store)

        let outcome = try await ReminderActionHandler(store: store)
            .handle(actionIdentifier: ReminderAction.snoozeID, taskID: "t1")

        #expect(outcome == .snoozed)
        #expect(try await store.fetchTask(id: "t1")?.snoozedUntil == now.addingTimeInterval(3600))
        #expect(q.ops.map(\.op) == [.update])
    }

    @Test(arguments: [ReminderAction.completeID, ReminderAction.snoozeID])
    func aTaskThatNoLongerExistsIsIgnored(action: String) async throws {
        let q = RecordingQueue(); let store = try makeStore(q)
        let outcome = try await ReminderActionHandler(store: store).handle(actionIdentifier: action, taskID: "gone")
        #expect(outcome == .ignored)
        #expect(q.ops.isEmpty)
    }

    @Test func snoozeOnACompletedTaskIsIgnored() async throws {
        let q = RecordingQueue(); let store = try makeStore(q)
        try await seed(store, completed: true)
        let outcome = try await ReminderActionHandler(store: store)
            .handle(actionIdentifier: ReminderAction.snoozeID, taskID: "t1")
        #expect(outcome == .ignored)
        #expect(try await store.fetchTask(id: "t1")?.snoozedUntil == nil)
    }

    @Test func aSavedItemIsNeverCompletedOrSnoozedFromANotification() async throws {
        let q = RecordingQueue(); let store = try makeStore(q)
        try await seed(store, saved: true)
        let handler = ReminderActionHandler(store: store)
        #expect(try await handler.handle(actionIdentifier: ReminderAction.completeID, taskID: "t1") == .ignored)
        #expect(try await handler.handle(actionIdentifier: ReminderAction.snoozeID, taskID: "t1") == .ignored)
        #expect(q.ops.isEmpty)
    }

    @Test func otherActionsAreIgnored() async throws {
        let q = RecordingQueue(); let store = try makeStore(q)
        try await seed(store)
        let outcome = try await ReminderActionHandler(store: store)
            .handle(actionIdentifier: "com.apple.UNNotificationDefaultActionIdentifier", taskID: "t1")
        #expect(outcome == .ignored)
        #expect(try await store.fetchTask(id: "t1")?.completed == false)
    }
}
