import Testing
import Foundation
import GSDModel
@testable import GSDStore

struct TaskRepositoryReplaceTests {
    private func task(_ id: String) -> Task {
        Task(id: id, title: id, urgent: false, important: false,
             createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
    }

    @Test func replaceAllClearsThenInserts() async throws {
        let repo = GRDBTaskRepository(try AppDatabase.inMemory())
        try await repo.upsert(task("old1"))
        try await repo.upsert(task("old2"))
        try await repo.replaceAll([task("new1"), task("new2"), task("new3")])
        let all = try await repo.fetchAll()
        #expect(Set(all.map(\.id)) == ["new1", "new2", "new3"])
    }
    @Test func replaceAllWithEmptyClearsEverything() async throws {
        let repo = GRDBTaskRepository(try AppDatabase.inMemory())
        try await repo.upsert(task("a"))
        try await repo.replaceAll([])
        #expect(try await repo.fetchAll().isEmpty)
    }
}
