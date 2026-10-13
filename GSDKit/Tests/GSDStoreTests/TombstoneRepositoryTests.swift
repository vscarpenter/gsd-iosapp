import Testing
import Foundation
import GSDModel
@testable import GSDStore

/// Parity S9 (backlog B-04): the archive and the trash act as sync tombstones. Sync asks when a
/// task was archived or trashed, and moves it back to the live table in one write when a newer
/// remote edit outranks that.
struct TombstoneRepositoryTests {
    private func task(_ id: String, title: String = "t") -> Task {
        Task(id: id, title: title, urgent: false, important: false,
             createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1))
    }
    private let buriedAt = Date(timeIntervalSince1970: 5_000)

    @Test func aLiveTaskHasNoTombstone() async throws {
        let db = try AppDatabase.inMemory()
        try await GRDBTaskRepository(db).upsert(task("a"))
        #expect(try await GRDBTombstoneRepository(db).tombstoneDate(id: "a") == nil)
    }

    @Test func anArchivedTaskReportsWhenItWasArchived() async throws {
        let db = try AppDatabase.inMemory()
        try await GRDBArchiveRepository(db).archive(task("a"), at: buriedAt)
        #expect(try await GRDBTombstoneRepository(db).tombstoneDate(id: "a") == buriedAt)
    }

    @Test func aTrashedTaskReportsWhenItWasDeleted() async throws {
        let db = try AppDatabase.inMemory()
        try await GRDBTrashRepository(db).trash(task("a"), at: buriedAt)
        #expect(try await GRDBTombstoneRepository(db).tombstoneDate(id: "a") == buriedAt)
    }

    @Test func resurrectMovesAnArchivedTaskBackToTheLiveTable() async throws {
        let db = try AppDatabase.inMemory()
        try await GRDBArchiveRepository(db).archive(task("a"), at: buriedAt)
        try await GRDBTombstoneRepository(db).resurrect(task("a", title: "edited elsewhere"))
        let live = try await GRDBTaskRepository(db).fetch(id: "a")
        #expect(live?.title == "edited elsewhere")
        #expect(try await GRDBArchiveRepository(db).fetchAll().isEmpty)
    }

    @Test func resurrectMovesATrashedTaskBackToTheLiveTable() async throws {
        let db = try AppDatabase.inMemory()
        try await GRDBTrashRepository(db).trash(task("a"), at: buriedAt)
        try await GRDBTombstoneRepository(db).resurrect(task("a", title: "edited elsewhere"))
        let live = try await GRDBTaskRepository(db).fetch(id: "a")
        #expect(live?.title == "edited elsewhere")
        #expect(try await GRDBTrashRepository(db).fetchAll().isEmpty)
    }
}
