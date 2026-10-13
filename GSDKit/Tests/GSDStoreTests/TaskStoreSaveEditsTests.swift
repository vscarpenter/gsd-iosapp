import Testing
import Foundation
import GSDModel
@testable import GSDStore

/// Parity C10 (backlog B-03). The editor used to save the snapshot it opened with, under a fresh
/// timestamp, so a completion or edit synced in while it was open was lost here and then lost on
/// the server too, because the stale row won last-write-wins. `saveEdits` merges onto the row as
/// it is now.
@MainActor
struct TaskStoreSaveEditsTests {
    private let opened = Date(timeIntervalSince1970: 1_780_000_000)
    private let saved = Date(timeIntervalSince1970: 1_780_000_600)

    private func makeStore() throws -> (TaskStore, AppDatabase, GRDBSyncQueueRepository) {
        let db = try AppDatabase.inMemory()
        let queue = GRDBSyncQueueRepository(db)
        let now = saved
        let store = TaskStore(repository: GRDBTaskRepository(db, now: { now }),
                              smartViewRepository: GRDBSmartViewRepository(db),
                              archiveRepository: GRDBArchiveRepository(db, now: { now }),
                              trashRepository: GRDBTrashRepository(db, now: { now }),
                              defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!,
                              clock: { now }, newID: { "id" },
                              syncQueue: queue)
        return (store, db, queue)
    }
    private func task() -> Task {
        Task(id: "a", title: "opened", urgent: false, important: true, createdAt: opened, updatedAt: opened)
    }

    @Test func keepsACompletionSyncedInWhileTheEditorWasOpen() async throws {
        let (store, db, _) = try makeStore()
        let original = task()
        try await GRDBTaskRepository(db).upsert(original)
        // Another device completed the task; pull wrote it straight to the repository.
        var pulled = original
        pulled.completed = true; pulled.completedAt = opened.addingTimeInterval(60)
        pulled.updatedAt = opened.addingTimeInterval(60)
        try await GRDBTaskRepository(db).upsert(pulled)

        var edited = original; edited.title = "retitled"
        let wrote = try await store.saveEdits(edited, openedAs: original)

        let stored = try #require(try await GRDBTaskRepository(db).fetch(id: "a"))
        #expect(wrote)
        #expect(stored.title == "retitled")
        #expect(stored.completed)
        #expect(stored.updatedAt == saved)
    }

    @Test func queuesTheMergedRowForSync() async throws {
        // The payload is what reaches the server, so it must carry the merge, not the snapshot.
        let (store, db, queue) = try makeStore()
        let original = task()
        var pulled = original; pulled.completed = true; pulled.updatedAt = opened.addingTimeInterval(60)
        try await GRDBTaskRepository(db).upsert(pulled)

        var edited = original; edited.title = "retitled"
        try await store.saveEdits(edited, openedAs: original)

        let payload = try #require(try await queue.pending().last?.payload)
        #expect(payload.title == "retitled")
        #expect(payload.completed)
    }

    @Test func writesNothingWhenTheTaskIsGone() async throws {
        let (store, db, queue) = try makeStore()
        let original = task()   // opened in the editor, then deleted elsewhere: no live row

        var edited = original; edited.title = "retitled"
        let wrote = try await store.saveEdits(edited, openedAs: original)

        #expect(!wrote)
        #expect(try await GRDBTaskRepository(db).fetch(id: "a") == nil)
        #expect(try await queue.pending().isEmpty)
    }
}
