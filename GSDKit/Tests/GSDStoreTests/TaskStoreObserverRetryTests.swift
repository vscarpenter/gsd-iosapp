import Testing
import Foundation
import GSDModel
@testable import GSDStore

/// Fix D: a thrown observation must not freeze the UI for the session — the store retries
/// (bounded) and the stream's next incarnation repopulates the snapshot.
@MainActor
struct TaskStoreObserverRetryTests {
    final class FlakyObserveRepository: TaskRepository, @unchecked Sendable {
        struct Boom: Error {}
        var attempts = 0
        func observeAll() -> AsyncThrowingStream<[Task], Error> {
            attempts += 1
            let attempt = attempts
            return AsyncThrowingStream { cont in
                if attempt == 1 {
                    cont.finish(throwing: Boom())   // first stream dies immediately
                } else {
                    cont.yield([Task(id: "a", title: "back", urgent: false, important: false,
                                     createdAt: Date(timeIntervalSince1970: 0),
                                     updatedAt: Date(timeIntervalSince1970: 0))])
                    // stream stays open like a real observation
                }
            }
        }
        func upsert(_ task: Task) async throws {}
        func fetchAll() async throws -> [Task] { [] }
        func fetch(id: String) async throws -> Task? { nil }
        func delete(id: String) async throws {}
        func replaceAll(_ tasks: [Task]) async throws {}
    }

    @Test func observerRecoversAfterAThrownStream() async throws {
        let db = try AppDatabase.inMemory()
        let repo = FlakyObserveRepository()
        let store = TaskStore(repository: repo,
                              smartViewRepository: GRDBSmartViewRepository(db),
                              archiveRepository: GRDBArchiveRepository(db),
                              defaults: UserDefaults(suiteName: "t.\(UUID().uuidString)")!)
        store.start()
        var waited = 0
        while store.tasks.isEmpty && waited < 300 {                  // retry sleeps 1 s; allow 3 s
            try await _Concurrency.Task.sleep(for: .milliseconds(10)); waited += 1
        }
        #expect(store.tasks.map(\.id) == ["a"])                      // second stream repopulated
        #expect(repo.attempts == 2)
    }
}
