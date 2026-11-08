import Testing
import Foundation
import GSDModel
@testable import GSDStore

/// `setFocus` writes a pick onto the row as it is now, so an edit that landed between a caller's
/// read and this write survives (the watch applier reads, awaits, then writes).
@MainActor
struct TaskStoreSetFocusTests {
    private func makeStore() throws -> TaskStore {
        let db = try AppDatabase.inMemory()
        return TaskStore(repository: GRDBTaskRepository(db, now: { Date(timeIntervalSince1970: 0) }),
                         smartViewRepository: GRDBSmartViewRepository(db),
                         archiveRepository: GRDBArchiveRepository(db, now: { Date(timeIntervalSince1970: 0) }),
                         trashRepository: GRDBTrashRepository(db, now: { Date(timeIntervalSince1970: 0) }),
                         defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!,
                         clock: { Date(timeIntervalSince1970: 10_000) }, newID: { "id" }, calendar: .current)
    }

    private func task(_ title: String) -> Task {
        Task(id: "a", title: title, urgent: false, important: true,
             createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
    }

    @Test func setsThePickOnTheStoredRow() async throws {
        let store = try makeStore()
        try await store.create(task("old"))
        try await store.setFocus(id: "a", date: "2027-01-15", rank: 2)
        let stored = try #require(try await store.fetchTask(id: "a"))
        #expect(stored.focusDate == "2027-01-15" && stored.focusRank == 2)
    }

    @Test func anEditMadeAfterTheCallersReadSurvives() async throws {
        let store = try makeStore()
        try await store.create(task("old"))
        let stale = try #require(try await store.fetchTask(id: "a"))     // what the caller read first
        var edited = stale; edited.title = "edited elsewhere"
        try await store.save(edited)                                      // a pull or phone edit lands
        try await store.setFocus(id: "a", date: "2027-01-15", rank: 1)
        let stored = try #require(try await store.fetchTask(id: "a"))
        #expect(stored.title == "edited elsewhere")
        #expect(stored.focusRank == 1)
    }

    @Test func clearsThePick() async throws {
        let store = try makeStore()
        try await store.create(task("old"))
        try await store.setFocus(id: "a", date: "2027-01-15", rank: 1)
        try await store.setFocus(id: "a", date: nil, rank: nil)
        let stored = try #require(try await store.fetchTask(id: "a"))
        #expect(stored.focusDate == nil && stored.focusRank == nil)
    }

    @Test func aMissingRowIsANoOp() async throws {
        let store = try makeStore()
        try await store.setFocus(id: "ghost", date: "2027-01-15", rank: 1)
        #expect(try await store.fetchTask(id: "ghost") == nil)
    }
}
