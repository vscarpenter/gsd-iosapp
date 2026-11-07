import Testing
import Foundation
import GSDModel
@testable import GSDStore

/// Top three spec section 7: backup envelope 2.2.0, read from a real web export
/// (`web-top-three-2.2.0.json`, frozen, byte-identical in all three repos).
@MainActor
struct TopThreeBackupTests {
    private let now = Date(timeIntervalSince1970: 1_794_067_200)   // 2026-11-07T12:00:00Z

    private func makeStore() throws -> TaskStore {
        let db = try AppDatabase.inMemory()
        let fixed = now
        return TaskStore(repository: GRDBTaskRepository(db, now: { fixed }),
                         smartViewRepository: GRDBSmartViewRepository(db),
                         archiveRepository: GRDBArchiveRepository(db, now: { fixed }),
                         trashRepository: GRDBTrashRepository(db, now: { fixed }),
                         defaults: UserDefaults(suiteName: "top-three-backup-\(UUID().uuidString)")!,
                         clock: { fixed }, syncQueue: GRDBSyncQueueRepository(db))
    }

    private func webBackup() throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "web-top-three-2.2.0", withExtension: "json",
                                                 subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private func restored() async throws -> TaskStore {
        let store = try makeStore()
        try await store.importTasks(try webBackup(), mode: .replace)
        store.start()                                   // export reads the observed snapshot
        for _ in 0..<100 where store.tasks.count != 3 { try await _Concurrency.Task.sleep(for: .milliseconds(10)) }
        return store
    }

    private func pick(_ task: Task?) -> String? {
        guard let task, let date = task.focusDate, let rank = task.focusRank else { return nil }
        return "\(date) #\(rank)"
    }

    @Test func restoringTheWebBackupBringsBackEveryPick() async throws {
        let store = try await restored()

        #expect(pick(try await store.fetchTask(id: "xiDU_5CYf636")) == "2026-11-07 #1")
        #expect(pick(try await store.fetchTask(id: "p9oPwowyf0AD")) == "2026-11-07 #2")
        #expect(pick(try await store.fetchTask(id: "VMU6izYEey7X")) == nil)
        #expect(pick(try await store.archivedTasksStamped().first?.task) == "2026-11-06 #1")
        #expect(pick(try await store.trashedTasks().first?.task) == "2026-11-07 #3")
    }

    @Test func reExportingWritesEnvelope220WithEachPickAndNoKeysForAnUnpickedTask() async throws {
        let out = try await (try await restored()).exportJSON()
        let object = try #require(try JSONSerialization.jsonObject(with: out) as? [String: Any])
        let byID = { (key: String) -> [String: [String: Any]] in
            Dictionary(uniqueKeysWithValues: ((object[key] as? [[String: Any]]) ?? []).map { ($0["id"] as? String ?? "", $0) })
        }

        #expect(object["version"] as? String == "2.2.0")
        #expect(byID("tasks")["p9oPwowyf0AD"]?["focusDate"] as? String == "2026-11-07")
        #expect(byID("tasks")["p9oPwowyf0AD"]?["focusRank"] as? Int == 2)
        let unpicked = try #require(byID("tasks")["VMU6izYEey7X"])
        #expect(unpicked["focusDate"] == nil && unpicked["focusRank"] == nil)
        #expect(byID("archivedTasks")["038j6XMhM6_j"]?["focusRank"] as? Int == 1)
        #expect(byID("deletedTasks")["wo2IKQc1Bowt"]?["focusRank"] as? Int == 3)
    }

    /// Spec 3.5 and section 7: a bad pick must not refuse a whole backup.
    @Test func anInvalidPickInABackupIsUnsetAndTheTaskKept() async throws {
        var object = try #require(try JSONSerialization.jsonObject(with: try webBackup()) as? [String: Any])
        var tasks = try #require(object["tasks"] as? [[String: Any]])
        let index = try #require(tasks.firstIndex { $0["id"] as? String == "p9oPwowyf0AD" })
        tasks[index]["focusRank"] = 7
        object["tasks"] = tasks
        let store = try makeStore()

        try await store.importTasks(try JSONSerialization.data(withJSONObject: object), mode: .replace)

        let task = try #require(try await store.fetchTask(id: "p9oPwowyf0AD"))
        #expect(task.title == "Call the venue" && pick(task) == nil)
    }
}
