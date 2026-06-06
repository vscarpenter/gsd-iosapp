import Testing
import Foundation
import GSDModel
@testable import GSDStore

@MainActor
struct TaskStoreTests {
    private let fixed = Date(timeIntervalSince1970: 1000)

    private func makeStoreAndRepo() throws -> (TaskStore, GRDBTaskRepository) {
        let db = try AppDatabase.inMemory()
        let repo = GRDBTaskRepository(db, now: { Date(timeIntervalSince1970: 1000) })
        let store = TaskStore(repository: repo,
                              smartViewRepository: GRDBSmartViewRepository(db),
                              archiveRepository: GRDBArchiveRepository(db, now: { Date(timeIntervalSince1970: 1000) }),
                              defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!,
                              clock: { Date(timeIntervalSince1970: 1000) },
                              newID: { "fixed-id" })
        return (store, repo)
    }

    @Test func addBuildsValidatedTaskFromParse() async throws {
        let (store, repo) = try makeStoreAndRepo()
        try await store.add(ParsedCapture(title: "Buy milk", urgent: true, important: true,
                                          tags: ["errand"], descriptionAdditions: ["https://x.com"]))
        let stored = try await repo.fetch(id: "fixed-id")
        #expect(stored?.title == "Buy milk")
        #expect(stored?.quadrant == .urgentImportant)
        #expect(stored?.tags == ["errand"])
        #expect(stored?.description == "https://x.com")
        #expect(stored?.createdAt == fixed && stored?.updatedAt == fixed)
    }

    @Test func addAppliesQuadrantOverride() async throws {
        let (store, repo) = try makeStoreAndRepo()
        try await store.add(ParsedCapture(title: "X", urgent: false, important: false, tags: [], descriptionAdditions: []),
                            override: .urgentImportant)
        #expect(try await repo.fetch(id: "fixed-id")?.quadrant == .urgentImportant)
    }

    @Test func toggleCompleteSetsCompletedAtAndBumpsUpdatedAt() async throws {
        let (store, repo) = try makeStoreAndRepo()
        try await store.add(ParsedCapture(title: "X", urgent: false, important: false, tags: [], descriptionAdditions: []))
        var t = try #require(try await repo.fetch(id: "fixed-id"))
        try await store.toggleComplete(t)
        t = try #require(try await repo.fetch(id: "fixed-id"))
        #expect(t.completed && t.completedAt == fixed)
        try await store.toggleComplete(t)
        #expect(try await repo.fetch(id: "fixed-id")?.completedAt == nil)
    }

    @Test func observationPropagatesToTasks() async throws {
        let (store, _) = try makeStoreAndRepo()
        store.start()
        try await store.add(ParsedCapture(title: "Visible", urgent: false, important: false, tags: [], descriptionAdditions: []))
        // Drain until the snapshot reflects the insert (observation is async).
        var waited = 0
        while store.tasks.isEmpty && waited < 100 { try await _Concurrency.Task.sleep(for: .milliseconds(10)); waited += 1 }
        #expect(store.tasks.first?.title == "Visible")
    }

    @Test func createStampsBothTimestampsFromClock() async throws {
        let (store, repo) = try makeStoreAndRepo()
        let stale = Date(timeIntervalSince1970: 5)
        let t = Task(id: "made", title: "X", urgent: true, important: false, createdAt: stale, updatedAt: stale)
        try await store.create(t)
        let stored = try await repo.fetch(id: "made")
        #expect(stored?.createdAt == Date(timeIntervalSince1970: 1000))
        #expect(stored?.updatedAt == Date(timeIntervalSince1970: 1000))
    }

    @Test func saveCanonicalizesTagsToLowercaseDeduped() async throws {
        let (store, repo) = try makeStoreAndRepo()
        let now = Date(timeIntervalSince1970: 1000)
        let t = Task(id: "mixed", title: "X", urgent: true, important: false,
                     createdAt: now, updatedAt: now, tags: ["Work", "work", "URGENT"])
        try await store.save(t)
        #expect(try await repo.fetch(id: "mixed")?.tags == ["work", "urgent"])
    }

    @Test func createCanonicalizesTagsToLowercaseDeduped() async throws {
        let (store, repo) = try makeStoreAndRepo()
        let now = Date(timeIntervalSince1970: 1000)
        let t = Task(id: "made2", title: "X", urgent: true, important: false,
                     createdAt: now, updatedAt: now, tags: ["Home", "HOME"])
        try await store.create(t)
        #expect(try await repo.fetch(id: "made2")?.tags == ["home"])
    }

    @Test func tasksInQuadrantSortsIncompleteFirst() async throws {
        let (store, repo) = try makeStoreAndRepo()
        let now = Date(timeIntervalSince1970: 1000)
        try await repo.upsert(Task(id: "done", title: "done", urgent: true, important: true,
                                   completed: true, createdAt: now, updatedAt: now))
        try await repo.upsert(Task(id: "open", title: "open", urgent: true, important: true,
                                   createdAt: now, updatedAt: now))
        store.start()
        var waited = 0
        while store.tasks.count < 2 && waited < 100 { try await _Concurrency.Task.sleep(for: .milliseconds(10)); waited += 1 }
        let q1 = store.tasks(in: .urgentImportant, showCompleted: true)
        #expect(q1.map(\.id) == ["open", "done"])
        #expect(store.tasks(in: .urgentImportant, showCompleted: false).map(\.id) == ["open"])
    }
}
