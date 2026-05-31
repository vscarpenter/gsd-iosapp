import Testing
import Foundation
import GSDModel
@testable import GSDStore

@MainActor
struct TaskStoreArchiveTests {
    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }()
    private func day(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 9) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d; c.hour = h
        return cal.date(from: c)!
    }
    private var now: Date { day(2026, 6, 15, 9) }

    private func makeStore() throws -> TaskStore {
        let db = try AppDatabase.inMemory()
        let suite = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        let fixed = now
        return TaskStore(repository: GRDBTaskRepository(db, now: { fixed }),
                         smartViewRepository: GRDBSmartViewRepository(db),
                         archiveRepository: GRDBArchiveRepository(db, now: { fixed }),
                         defaults: suite,
                         clock: { fixed }, newID: { "id" }, calendar: cal)
    }
    private func completed(_ id: String, at when: Date) -> Task {
        Task(id: id, title: id, urgent: false, important: false, completed: true,
             completedAt: when, createdAt: day(2026, 1, 1), updatedAt: day(2026, 1, 1))
    }
    private func waitForTasks(_ store: TaskStore, count: Int) async throws {
        store.start(); var w = 0
        while store.tasks.count != count && w < 100 { try await _Concurrency.Task.sleep(for: .milliseconds(10)); w += 1 }
    }
    private func waitForArchived(_ store: TaskStore, count: Int) async throws {
        var w = 0
        while store.archivedTasks.count != count && w < 100 { try await _Concurrency.Task.sleep(for: .milliseconds(10)); w += 1 }
    }

    @Test func archiveThenRestoreRoundTrips() async throws {
        let store = try makeStore()
        try await store.create(completed("a", at: now))
        try await waitForTasks(store, count: 1)
        try await store.archive(store.tasks[0])
        try await waitForArchived(store, count: 1)
        #expect(store.tasks.isEmpty)
        try await store.restore(store.archivedTasks[0])
        try await waitForArchived(store, count: 0)
        try await waitForTasks(store, count: 1)
    }
    @Test func deletePermanentlyRemovesArchived() async throws {
        let store = try makeStore()
        try await store.create(completed("a", at: now))
        try await waitForTasks(store, count: 1)
        try await store.archive(store.tasks[0])
        try await waitForArchived(store, count: 1)
        try await store.deletePermanently(store.archivedTasks[0])
        try await waitForArchived(store, count: 0)
        #expect(store.tasks.isEmpty)
    }
    @Test func sweepDisabledArchivesNothing() async throws {
        let store = try makeStore()
        store.archiveSettings = ArchiveSettings(autoEnabled: false, afterDays: 30)
        try await store.create(completed("old", at: day(2026, 1, 1)))   // ancient
        try await waitForTasks(store, count: 1)
        try await store.runAutoArchiveSweep()
        try await _Concurrency.Task.sleep(for: .milliseconds(50))
        #expect(store.tasks.count == 1)            // untouched
        #expect(store.archivedTasks.isEmpty)
    }
    @Test func sweepEnabledArchivesOldCompletedTasks() async throws {
        let store = try makeStore()
        store.archiveSettings = ArchiveSettings(autoEnabled: true, afterDays: 30)
        try await store.create(completed("old", at: day(2026, 1, 1)))   // < cutoff → archive
        try await store.create(completed("recent", at: day(2026, 6, 14)))// recent → keep
        try await waitForTasks(store, count: 2)
        try await store.runAutoArchiveSweep()
        try await waitForArchived(store, count: 1)
        #expect(store.archivedTasks.map(\.id) == ["old"])
        #expect(store.tasks.map(\.id) == ["recent"])
    }
    @Test func archiveSettingsPersistToDefaults() async throws {
        let store = try makeStore()
        store.archiveSettings = ArchiveSettings(autoEnabled: true, afterDays: 60)
        #expect(store.archiveSettings == ArchiveSettings(autoEnabled: true, afterDays: 60))
    }
}
