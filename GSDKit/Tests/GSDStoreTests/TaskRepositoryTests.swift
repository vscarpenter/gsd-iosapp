import Testing
import Foundation
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
}
