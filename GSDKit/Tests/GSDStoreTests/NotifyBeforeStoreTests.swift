import Testing
import Foundation
import GSDModel
@testable import GSDStore

/// D-10 (spec-notify-before): a written task stores a number, resolved against this device's
/// Default reminder at write time. Reads keep `notifyBefore ?? default` for legacy null rows.
@MainActor
struct NotifyBeforeStoreTests {
    private let stamp = Date(timeIntervalSince1970: 1_780_000_000)

    private func makeStore(defaultReminder: Int = 30) throws -> (TaskStore, GRDBTaskRepository, UserDefaults) {
        let db = try AppDatabase.inMemory()
        let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        defaults.set(defaultReminder, forKey: AppGroupDefaults.Key.notificationDefaultReminder)
        let repo = GRDBTaskRepository(db)
        let store = TaskStore(repository: repo, smartViewRepository: GRDBSmartViewRepository(db),
                              archiveRepository: GRDBArchiveRepository(db), trashRepository: GRDBTrashRepository(db),
                              defaults: defaults, clock: { Date(timeIntervalSince1970: 1_780_000_600) },
                              newID: { "new-id" }, syncQueue: GRDBSyncQueueRepository(db))
        return (store, repo, defaults)
    }
    private func task(_ id: String = "a", offset: Int? = nil) -> Task {
        Task(id: id, title: "t", urgent: false, important: false, createdAt: stamp, updatedAt: stamp, notifyBefore: offset)
    }

    @Test func aNewTaskWithNoOffsetStoresTheDefault() async throws {
        let (store, repo, _) = try makeStore(defaultReminder: 30)
        try await store.create(task())
        #expect(try await repo.fetch(id: "a")?.notifyBefore == 30)
    }

    @Test func aZeroOffsetStaysZero() async throws {
        let (store, repo, _) = try makeStore()
        try await store.create(task(offset: 0))
        #expect(try await repo.fetch(id: "a")?.notifyBefore == 0)
    }

    @Test func aCaptureBarTaskStoresTheDefault() async throws {
        let (store, repo, _) = try makeStore(defaultReminder: 60)
        try await store.add(CaptureParser.parse("Call mom"))
        #expect(try await repo.fetchAll().first?.notifyBefore == 60)
    }

    @Test func changingTheDefaultDoesntMoveAnExistingNumber() async throws {
        let (store, repo, defaults) = try makeStore(defaultReminder: 30)
        try await store.create(task())
        defaults.set(60, forKey: AppGroupDefaults.Key.notificationDefaultReminder)
        var current = try #require(try await repo.fetch(id: "a"))
        current.title = "edited"
        try await store.save(current)
        #expect(try await repo.fetch(id: "a")?.notifyBefore == 30)
    }

    @Test func anyEditorSaveOfALegacyNullSettlesTheDefault() async throws {
        let (store, repo, _) = try makeStore(defaultReminder: 15)
        try await repo.upsert(task(offset: nil))   // a legacy row, written before D-10
        var legacy = try #require(try await repo.fetch(id: "a"))
        legacy.title = "edited"
        try await store.save(legacy)
        #expect(try await repo.fetch(id: "a")?.notifyBefore == 15)
    }

    @Test func aDuplicateStoresANumber() async throws {
        let (store, repo, _) = try makeStore(defaultReminder: 15)
        try await repo.upsert(task(offset: nil))
        let copy = try await store.duplicate(try #require(try await repo.fetch(id: "a")))
        #expect(try await repo.fetch(id: copy.id)?.notifyBefore == 15)
    }

    @Test func aBackupWithNoOffsetImportsWithTheDefault() async throws {
        for mode in [TaskStore.ImportMode.replace, .merge] {
            let (store, repo, _) = try makeStore(defaultReminder: 60)
            let data = try TaskExport.encode(TaskExport(tasks: [task("imp", offset: nil), task("kept", offset: 0)],
                                                        exportedAt: stamp))
            try await store.importTasks(data, mode: mode)
            #expect(try await repo.fetch(id: "imp")?.notifyBefore == 60)
            #expect(try await repo.fetch(id: "kept")?.notifyBefore == 0)
        }
    }

    @Test func aBackupWithNoOffsetTakesTheDefaultInEffectAfterTheImportFinishes() async throws {
        // D3: the backup's own settings are restored by the import, so its default is the one in effect.
        for mode in [TaskStore.ImportMode.replace, .merge] {
            let (store, repo, _) = try makeStore(defaultReminder: 15)
            let backupSettings = NotificationSettings(enabled: true, defaultReminder: 60)
            let data = try TaskExport.encode(TaskExport(
                tasks: [task("imp", offset: nil)], exportedAt: stamp,
                notificationSettings: NotificationSettingsWire(backupSettings, updatedAt: stamp)))
            try await store.importTasks(data, mode: mode)
            #expect(store.notificationSettings.defaultReminder == 60)
            #expect(try await repo.fetch(id: "imp")?.notifyBefore == 60)
        }
    }

    @Test func aLegacyNullStillFiresTheDefaultUntilItIsWritten() {
        let inputs = ReminderMath.Inputs(masterEnabled: true, defaultReminder: 15)
        let due = Date(timeIntervalSince1970: 1_790_000_000)
        var legacy = task(offset: nil); legacy.dueDate = due
        var settled = legacy; settled.notifyBefore = 15
        #expect(ReminderMath.fireDate(for: legacy, inputs: inputs, now: stamp) == ReminderMath.fireDate(for: settled, inputs: inputs, now: stamp))
    }
}
