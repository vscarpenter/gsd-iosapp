import Foundation
import GRDB
import Testing
import GSDModel
@testable import GSDStore

struct SavedPersistenceTests {
    private let now = Date(timeIntervalSince1970: 1_793_016_000)

    private func savedTask() -> Task {
        Task(id: "reading", title: "Read this article", urgent: false, important: true,
             createdAt: now, updatedAt: now, savedAt: now)
    }

    @MainActor private func awaitSnapshot(_ store: TaskStore, matching predicate: (Task) -> Bool) async throws {
        for _ in 0..<100 {
            if store.tasks.contains(where: predicate) { return }
            try await _Concurrency.Task.sleep(for: .milliseconds(10))
        }
        let matched = store.tasks.contains(where: predicate)
        try #require(matched, "Expected task observation did not arrive")
    }

    @Test func upgradePreservesLegacyTasksAndAddsNullablePlacement() async throws {
        let queue = try DatabaseQueue()
        var old = DatabaseMigrator()
        AppDatabase.registerV1(&old)
        AppDatabase.registerV2(&old)
        AppDatabase.registerV3(&old)
        AppDatabase.registerV4(&old)
        AppDatabase.registerV5(&old)
        AppDatabase.registerV6(&old)
        try old.migrate(queue)
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO tasks (id,title,urgent,important,quadrant,createdAt,updatedAt)
                VALUES ('legacy','Keep me',0,1,'not-urgent-important',100,100)
                """)
        }
        let migrated = try AppDatabase(queue)
        let legacy = try #require(try await GRDBTaskRepository(migrated).fetch(id: "legacy"))
        #expect(legacy.title == "Keep me")
        #expect(legacy.savedAt == nil)
        try await GRDBTaskRepository(migrated).upsert(savedTask())
        #expect(try await GRDBTaskRepository(migrated).fetch(id: "reading") == savedTask())
    }

    @Test func trashAndArchiveRetainSavedPlacement() async throws {
        let db = try AppDatabase.inMemory()
        let saved = savedTask()
        let trash = GRDBTrashRepository(db)
        let archive = GRDBArchiveRepository(db)
        try await GRDBTaskRepository(db).upsert(saved)
        try await trash.trash(saved)
        #expect(try await trash.fetchAll().first?.savedAt == now)
        let restored = try #require(try await trash.restore(id: saved.id))
        try await archive.archive(restored)
        #expect(try await archive.fetchAll().first?.savedAt == now)
    }

    @Test @MainActor func productionWebBackupRoundTripsNativeNotesAndReturn() async throws {
        let url = try #require(Bundle.module.url(forResource: "web-saved-14.2.0", withExtension: "json", subdirectory: "Fixtures"))
        let data = try Data(contentsOf: url)
        let original = try #require(TaskExport.decode(data).tasks.first)
        let db = try AppDatabase.inMemory()
        let repo = GRDBTaskRepository(db)
        let stamp = now
        let store = TaskStore(repository: repo, smartViewRepository: GRDBSmartViewRepository(db),
                              archiveRepository: GRDBArchiveRepository(db), trashRepository: GRDBTrashRepository(db),
                              defaults: UserDefaults(suiteName: "saved-backup-\(UUID().uuidString)")!, clock: { stamp })
        store.start()
        _ = try await store.importTasks(data, mode: .replace)
        #expect(try await repo.fetch(id: original.id)?.savedAt == original.savedAt)
        try await store.updateSavedNotes(id: original.id, notes: "Native short note\nhttps://example.com/saved")
        try await awaitSnapshot(store) { $0.description == "Native short note\nhttps://example.com/saved" }
        let savedExport = try await store.exportJSON()
        #expect(try TaskExport.decode(savedExport).tasks.first?.savedAt == original.savedAt)
        try await store.returnToMatrix(id: original.id, quadrant: .urgentImportant, dueDate: nil)
        try await awaitSnapshot(store) { !$0.isSaved && $0.quadrant == .urgentImportant }
        let returnedExport = try await store.exportJSON()
        let returned = try #require(TaskExport.decode(returnedExport).tasks.first)
        #expect(!returned.isSaved && returned.quadrant == .urgentImportant && returned.id == original.id)
        if let directory = ProcessInfo.processInfo.environment["GSD_SAVED_EXPORT_DIR"] {
            try savedExport.write(to: URL(filePath: directory).appending(path: "ios-saved.json"))
            try returnedExport.write(to: URL(filePath: directory).appending(path: "ios-returned.json"))
        }
    }
}
