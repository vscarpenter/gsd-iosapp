import Testing
import Foundation
import GSDModel
@testable import GSDStore

struct ArchiveRepositoryTests {
    private let t0 = Date(timeIntervalSince1970: 0)
    private func task(_ id: String) -> Task {
        Task(id: id, title: id, urgent: false, important: false, completed: true,
             completedAt: t0, createdAt: t0, updatedAt: t0)
    }

    @Test func archiveMovesRowOutOfTasksIntoArchive() async throws {
        let db = try AppDatabase.inMemory()
        let tasks = GRDBTaskRepository(db, now: { self.t0 })
        let archive = GRDBArchiveRepository(db, now: { Date(timeIntervalSince1970: 5000) })
        try await tasks.upsert(task("a"))
        try await archive.archive(task("a"))
        #expect(try await tasks.fetch(id: "a") == nil)          // gone from active
        let archived = try await archive.fetchAll()
        #expect(archived.map(\.id) == ["a"])                    // present in archive
    }
    @Test func restoreMovesRowBackToTasks() async throws {
        let db = try AppDatabase.inMemory()
        let tasks = GRDBTaskRepository(db, now: { self.t0 })
        let archive = GRDBArchiveRepository(db, now: { self.t0 })
        try await tasks.upsert(task("a"))
        try await archive.archive(task("a"))
        try await archive.restore(id: "a")
        #expect(try await tasks.fetch(id: "a")?.id == "a")      // back in active
        #expect(try await archive.fetchAll().isEmpty)           // gone from archive
    }
    @Test func deletePermanentlyRemovesArchivedRow() async throws {
        let db = try AppDatabase.inMemory()
        let tasks = GRDBTaskRepository(db, now: { self.t0 })
        let archive = GRDBArchiveRepository(db, now: { self.t0 })
        try await tasks.upsert(task("a"))
        try await archive.archive(task("a"))
        try await archive.deletePermanently(id: "a")
        #expect(try await archive.fetchAll().isEmpty)
        #expect(try await tasks.fetch(id: "a") == nil)          // not resurrected
    }
    @Test func archivedTasksAreIsolatedFromActiveFetch() async throws {
        let db = try AppDatabase.inMemory()
        let tasks = GRDBTaskRepository(db, now: { self.t0 })
        let archive = GRDBArchiveRepository(db, now: { self.t0 })
        try await tasks.upsert(task("keep"))
        try await tasks.upsert(task("gone"))
        try await archive.archive(task("gone"))
        #expect(try await tasks.fetchAll().map(\.id) == ["keep"])  // archive excluded from active
    }
    @Test func observeAllEmitsInitialThenOnArchive() async throws {
        let db = try AppDatabase.inMemory()
        let tasks = GRDBTaskRepository(db, now: { self.t0 })
        let archive = GRDBArchiveRepository(db, now: { self.t0 })
        var iterator = archive.observeAll().makeAsyncIterator()
        #expect(try await iterator.next()?.isEmpty == true)
        try await tasks.upsert(task("x"))
        try await archive.archive(task("x"))
        var observed = try await iterator.next()
        while observed?.isEmpty == true { observed = try await iterator.next() }
        #expect(observed?.count == 1)
    }
}
