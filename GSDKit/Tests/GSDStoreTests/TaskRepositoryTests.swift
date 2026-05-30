import Testing
import Foundation
import GRDB
import GSDModel
@testable import GSDStore

struct TaskRepositoryTests {
    private func makeTask(id: String, dependencies: [String] = []) -> Task {
        Task(id: id, title: "T-\(id)", urgent: false, important: false,
             createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0),
             dependencies: dependencies)
    }

    @Test func upsertThenFetchReturnsTask() async throws {
        let repo = GRDBTaskRepository(try AppDatabase.inMemory())
        try await repo.upsert(makeTask(id: "a"))
        #expect(try await repo.fetch(id: "a")?.id == "a")
    }

    @Test func upsertUpdatesExistingRow() async throws {
        let repo = GRDBTaskRepository(try AppDatabase.inMemory())
        try await repo.upsert(makeTask(id: "a"))
        var updated = makeTask(id: "a")
        updated.title = "renamed"
        try await repo.upsert(updated)
        let all = try await repo.fetchAll()
        #expect(all.count == 1)
        #expect(all.first?.title == "renamed")
    }

    @Test func deleteRemovesIdFromOtherTasksDependencies() async throws {
        let repo = GRDBTaskRepository(try AppDatabase.inMemory())
        try await repo.upsert(makeTask(id: "blocker"))
        try await repo.upsert(makeTask(id: "blocked", dependencies: ["blocker"]))
        try await repo.delete(id: "blocker")
        #expect(try await repo.fetch(id: "blocked")?.dependencies.isEmpty == true)
        #expect(try await repo.fetch(id: "blocker") == nil)
    }

    @Test func deleteBumpsUpdatedAtOnScrubbedDependents() async throws {
        let fixed = Date(timeIntervalSince1970: 5000)
        let repo = GRDBTaskRepository(try AppDatabase.inMemory(), now: { fixed })
        try await repo.upsert(makeTask(id: "blocker"))
        var blocked = makeTask(id: "blocked", dependencies: ["blocker"])
        blocked.updatedAt = Date(timeIntervalSince1970: 0)   // old timestamp
        try await repo.upsert(blocked)
        try await repo.delete(id: "blocker")
        let after = try await repo.fetch(id: "blocked")
        #expect(after?.dependencies.isEmpty == true)
        #expect(after?.updatedAt == fixed)                   // scrub bumped updatedAt
    }

    @Test func observeAllEmitsInitialThenOnInsert() async throws {
        let repo = GRDBTaskRepository(try AppDatabase.inMemory())
        var iterator = repo.observeAll().makeAsyncIterator()
        #expect(try await iterator.next()?.isEmpty == true)  // initial snapshot
        try await repo.upsert(makeTask(id: "x"))
        // Drain until the insert is observed — ValueObservation may coalesce emissions.
        var observed = try await iterator.next()
        while observed?.isEmpty == true { observed = try await iterator.next() }
        #expect(observed?.count == 1)
    }

    @Test func persistedQuadrantColumnMatchesFlagsAfterWrite() async throws {
        let db = try AppDatabase.inMemory()
        let repo = GRDBTaskRepository(db)
        var t = makeTask(id: "q1")
        t.urgent = false; t.important = true            // -> not-urgent-important (Schedule)
        try await repo.upsert(t)
        let stored = try await db.writer.read { d in
            try String.fetchOne(d, sql: "SELECT quadrant FROM tasks WHERE id = ?", arguments: ["q1"])
        }
        #expect(stored == "not-urgent-important")
    }
}
