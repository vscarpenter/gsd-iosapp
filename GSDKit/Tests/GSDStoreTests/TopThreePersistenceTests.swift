import Foundation
import GRDB
import Testing
import GSDModel
@testable import GSDStore

/// GRDB `v8` (top three spec section 5): two nullable columns on every task table, no index, no backfill.
struct TopThreePersistenceTests {
    private let now = Date(timeIntervalSince1970: 1_793_016_000)

    private func pickedTask() -> Task {
        Task(id: "pick", title: "File the receipts", urgent: true, important: true,
             createdAt: now, updatedAt: now, focusDate: "2026-11-07", focusRank: 2)
    }

    @Test func v8AddsBothFieldsToEveryTaskTableWithoutAnIndex() throws {
        let db = try AppDatabase.inMemory()
        try db.writer.read { d in
            for table in ["tasks", "archivedTasks", "deletedTasks"] {
                let columns = try d.columns(in: table)
                let date = try #require(columns.first { $0.name == "focusDate" }, "\(table) lacks focusDate")
                let rank = try #require(columns.first { $0.name == "focusRank" }, "\(table) lacks focusRank")
                #expect(!date.isNotNull && !rank.isNotNull, "\(table)")
                let indexed = Set(try d.indexes(on: table).flatMap(\.columns))
                #expect(!indexed.contains("focusDate") && !indexed.contains("focusRank"), "\(table)")
            }
        }
    }

    @Test func upgradeFromV7KeepsEveryRowAndLeavesItUnpicked() async throws {
        let queue = try DatabaseQueue()
        var v7 = DatabaseMigrator()
        AppDatabase.registerV1(&v7)
        AppDatabase.registerV2(&v7)
        AppDatabase.registerV3(&v7)
        AppDatabase.registerV4(&v7)
        AppDatabase.registerV5(&v7)
        AppDatabase.registerV6(&v7)
        AppDatabase.registerV7(&v7)
        try v7.migrate(queue)
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO tasks (id,title,urgent,important,quadrant,createdAt,updatedAt,savedAt)
                VALUES ('saved','Read later',0,1,'not-urgent-important',100,100,100)
                """)
        }
        let migrated = try AppDatabase(queue)
        let row = try #require(try await GRDBTaskRepository(migrated).fetch(id: "saved"))
        #expect(row.title == "Read later" && row.isSaved)
        #expect(row.focusDate == nil && row.focusRank == nil)
    }

    @Test func aPickRoundTripsThroughTheActiveTable() async throws {
        let repo = GRDBTaskRepository(try AppDatabase.inMemory())
        try await repo.upsert(pickedTask())
        #expect(try await repo.fetch(id: "pick") == pickedTask())
    }

    @Test func trashAndArchiveKeepThePick() async throws {
        let db = try AppDatabase.inMemory()
        let trash = GRDBTrashRepository(db)
        let archive = GRDBArchiveRepository(db)
        try await GRDBTaskRepository(db).upsert(pickedTask())
        try await trash.trash(pickedTask())
        let trashed = try #require(try await trash.fetchAll().first)
        #expect(trashed.focusDate == "2026-11-07" && trashed.focusRank == 2)
        let restored = try #require(try await trash.restore(id: "pick"))
        try await archive.archive(restored)
        let archived = try #require(try await archive.fetchAll().first)
        #expect(archived.focusDate == "2026-11-07" && archived.focusRank == 2)
    }
}
