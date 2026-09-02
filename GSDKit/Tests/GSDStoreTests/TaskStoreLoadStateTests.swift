import Testing
import Foundation
import GSDModel
@testable import GSDStore

@MainActor
struct TaskStoreLoadStateTests {
    private func makeStore() throws -> TaskStore {
        let db = try AppDatabase.inMemory()
        let now: @Sendable () -> Date = { Date(timeIntervalSince1970: 1_700_000_000) }
        return TaskStore(
            repository: GRDBTaskRepository(db, now: now),
            smartViewRepository: GRDBSmartViewRepository(db),
            archiveRepository: GRDBArchiveRepository(db, now: now),
            trashRepository: GRDBTrashRepository(db, now: now),
            defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!,
            clock: now
        )
    }

    @Test func hasLoadedTasksIsFalseBeforeStart() throws {
        let store = try makeStore()
        #expect(store.hasLoadedTasks == false)
    }

    /// The flag is what lets the UI tell "loaded, and empty" apart from "not yet
    /// loaded" — an empty database must still flip it on the first snapshot.
    @Test func hasLoadedTasksFlipsOnFirstSnapshotEvenWhenEmpty() async throws {
        let store = try makeStore()
        store.start()
        var waited = 0
        while !store.hasLoadedTasks && waited < 100 {
            try await _Concurrency.Task.sleep(for: .milliseconds(10)); waited += 1
        }
        #expect(store.hasLoadedTasks)
        #expect(store.tasks.isEmpty)
    }
}
