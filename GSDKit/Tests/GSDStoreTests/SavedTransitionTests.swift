import Foundation
import Testing
import GSDModel
@testable import GSDStore

@MainActor
struct SavedTransitionTests {
    private let now = Date(timeIntervalSince1970: 1_793_016_000)

    private func makeStore() throws -> (TaskStore, GRDBTaskRepository, GRDBSyncQueueRepository, RecordingReminderScheduler) {
        let db = try AppDatabase.inMemory()
        let repo = GRDBTaskRepository(db)
        let queue = GRDBSyncQueueRepository(db)
        let reminders = RecordingReminderScheduler()
        let stamp = now
        let store = TaskStore(repository: repo, smartViewRepository: GRDBSmartViewRepository(db),
                              archiveRepository: GRDBArchiveRepository(db), trashRepository: GRDBTrashRepository(db),
                              defaults: UserDefaults(suiteName: "saved-\(UUID().uuidString)")!,
                              clock: { stamp }, reminders: reminders, syncQueue: queue)
        return (store, repo, queue, reminders)
    }

    private func task() -> Task {
        Task(id: "article", title: "Read the article", description: "https://example.com/article",
             urgent: false, important: true, createdAt: now.addingTimeInterval(-60),
             updatedAt: now.addingTimeInterval(-60), dueDate: now.addingTimeInterval(3600),
             recurrence: .weekly, tags: ["reading"],
             subtasks: [.init(id: "sub", title: "Keep context", completed: false)], dependencies: ["prior"])
    }

    @Test func savingPreservesContextCancelsReminderAndQueuesPlacement() async throws {
        let (store, repo, queue, reminders) = try makeStore()
        let original = task()
        try await repo.upsert(original)
        let saved = try await store.moveToSaved(original)
        var expected = original; expected.savedAt = now; expected.updatedAt = now
        #expect(saved == expected)
        #expect(try await repo.fetch(id: original.id) == expected)
        #expect(try await repo.fetchAll().count == 1)
        #expect(try await queue.all().last?.payload == expected)
        #expect(reminders.scheduleCancelCalls == [.cancel(original.id)])
    }

    @Test func returnUsesLatestNotesAndReviewedPlacement() async throws {
        let (store, repo, queue, reminders) = try makeStore()
        var saved = task(); saved.savedAt = now.addingTimeInterval(-30)
        saved.description = "Notes edited on the web"
        saved.snoozedUntil = now.addingTimeInterval(7200); saved.notificationSent = true
        try await repo.upsert(saved)
        let due = now.addingTimeInterval(86400)
        try await store.returnToMatrix(id: saved.id, quadrant: .urgentImportant, dueDate: due)
        let returned = try #require(try await repo.fetch(id: saved.id))
        #expect(returned.savedAt == nil)
        #expect(returned.description == saved.description)
        #expect(returned.quadrant == .urgentImportant)
        #expect(returned.dueDate == due)
        #expect(!returned.completed && !returned.notificationSent)
        #expect(returned.snoozedUntil == nil)
        #expect(returned.tags == saved.tags && returned.dependencies == saved.dependencies)
        #expect(try await queue.all().last?.payload == returned)
        #expect(reminders.scheduleCancelCalls == [.schedule(saved.id)])
    }

    @Test func notesUpdateOnlyTheLatestDescriptionAndRespectWebLimit() async throws {
        let (store, repo, _, _) = try makeStore()
        var saved = task(); saved.savedAt = now; saved.title = "Renamed on web"
        try await repo.upsert(saved)
        let limit = String(repeating: "😀", count: 300)
        try await store.updateSavedNotes(id: saved.id, notes: limit)
        let updated = try #require(try await repo.fetch(id: saved.id))
        #expect(updated.description == limit)
        #expect(updated.title == saved.title && updated.savedAt == saved.savedAt)
        await #expect(throws: ValidationError.descriptionTooLong) {
            try await store.updateSavedNotes(id: saved.id, notes: limit + "x")
        }
        try await store.updateSavedNotes(id: saved.id, notes: "")
        #expect(try await repo.fetch(id: saved.id)?.description == "")
    }

    @Test func savingRejectsCompletedAndRunningTasksWithoutWrites() async throws {
        let (store, repo, queue, _) = try makeStore()
        var completed = task(); completed.completed = true
        try await repo.upsert(completed)
        await #expect(throws: TaskStoreError.completedTaskCannotBeSaved) { try await store.moveToSaved(completed) }
        var running = task()
        running.timeEntries = [.init(id: "timer", startedAt: now, endedAt: nil, notes: nil)]
        try await repo.upsert(running)
        await #expect(throws: TaskStoreError.stopTimerBeforeSaving) { try await store.moveToSaved(running) }
        #expect(try await queue.all().isEmpty)
        #expect(try await repo.fetch(id: running.id)?.savedAt == nil)
    }

    @Test func staleCompletionAndTimerCannotActOnARemotelySavedTask() async throws {
        let (store, repo, queue, _) = try makeStore()
        let stale = task()
        var remote = stale; remote.savedAt = now
        try await repo.upsert(remote)
        await #expect(throws: TaskStoreError.savedItemRequiresReturn) { try await store.toggleComplete(stale) }
        await #expect(throws: TaskStoreError.savedItemRequiresReturn) { try await store.startTimer(stale) }
        #expect(try await queue.all().isEmpty)
    }

    @Test func ordinaryStaleEditsDoNotMoveAnItemOutOfSaved() async throws {
        let (store, repo, _, _) = try makeStore()
        let stale = task()
        var saved = stale; saved.savedAt = now
        try await repo.upsert(saved)
        try await store.move(stale, to: .urgentNotImportant)
        #expect(try await repo.fetch(id: stale.id)?.savedAt == now)
        try await store.save(stale)
        #expect(try await repo.fetch(id: stale.id)?.savedAt == now)
    }

    @Test func missingOrReturnedItemsAreNeverResurrectedByNotesOrReturn() async throws {
        let (store, repo, queue, _) = try makeStore()
        await #expect(throws: TaskStoreError.savedItemUnavailable) {
            try await store.updateSavedNotes(id: "missing", notes: "Keep")
        }
        try await repo.upsert(task())
        await #expect(throws: TaskStoreError.savedItemUnavailable) {
            try await store.returnToMatrix(id: "article", quadrant: .urgentImportant, dueDate: nil)
        }
        #expect(try await queue.all().isEmpty)
    }

    @Test func undoOnlyAppliesToTheUnchangedSavedTransition() async throws {
        let (store, repo, _, _) = try makeStore()
        let original = task(); try await repo.upsert(original)
        let saved = try await store.moveToSaved(original)
        try await store.undoMoveToSaved(saved)
        #expect(try await repo.fetch(id: saved.id)?.savedAt == nil)
        _ = try await store.moveToSaved(original)
        var remote = try #require(try await repo.fetch(id: saved.id))
        remote.updatedAt = now.addingTimeInterval(1); remote.description = "New web note"
        try await repo.upsert(remote)
        await #expect(throws: TaskStoreError.savedItemUnavailable) { try await store.undoMoveToSaved(saved) }
        #expect(try await repo.fetch(id: saved.id)?.description == "New web note")
    }

    @Test func ordinarySavedEditsAndSnoozeKeepRemindersCancelled() async throws {
        let (store, repo, _, reminders) = try makeStore()
        var saved = task(); saved.savedAt = now
        try await repo.upsert(saved)
        try await store.save(saved)
        try await store.snooze(saved, by: .oneHour)
        #expect(reminders.scheduleCancelCalls == [.cancel(saved.id), .cancel(saved.id)])
    }
}
