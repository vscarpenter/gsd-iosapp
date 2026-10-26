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
}
