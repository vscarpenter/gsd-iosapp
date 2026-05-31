import Testing
import Foundation
import GSDModel
@testable import GSDStore

struct SmartViewRepositoryTests {
    private func view(_ id: String, name: String = "V") -> SmartView {
        SmartView(id: id, name: name, icon: "star",
                  criteria: FilterCriteria(status: .active), isBuiltIn: false)
    }
    private let t0 = Date(timeIntervalSince1970: 0)

    @Test func upsertThenFetchAll() async throws {
        let repo = GRDBSmartViewRepository(try AppDatabase.inMemory())
        try await repo.upsert(view("a"), createdAt: t0, updatedAt: t0)
        let all = try await repo.fetchAll()
        #expect(all.map(\.id) == ["a"])
        #expect(all.first?.isBuiltIn == false)
    }
    @Test func upsertUpdatesExistingRow() async throws {
        let repo = GRDBSmartViewRepository(try AppDatabase.inMemory())
        try await repo.upsert(view("a", name: "Old"), createdAt: t0, updatedAt: t0)
        try await repo.upsert(view("a", name: "New"), createdAt: t0, updatedAt: t0)
        let all = try await repo.fetchAll()
        #expect(all.count == 1)
        #expect(all.first?.name == "New")
    }
    @Test func deleteRemovesRow() async throws {
        let repo = GRDBSmartViewRepository(try AppDatabase.inMemory())
        try await repo.upsert(view("a"), createdAt: t0, updatedAt: t0)
        try await repo.delete(id: "a")
        #expect(try await repo.fetchAll().isEmpty)
    }
    @Test func observeAllEmitsInitialThenOnInsert() async throws {
        let repo = GRDBSmartViewRepository(try AppDatabase.inMemory())
        var iterator = repo.observeAll().makeAsyncIterator()
        #expect(try await iterator.next()?.isEmpty == true)
        try await repo.upsert(view("x"), createdAt: t0, updatedAt: t0)
        var observed = try await iterator.next()
        while observed?.isEmpty == true { observed = try await iterator.next() }
        #expect(observed?.count == 1)
    }
}
