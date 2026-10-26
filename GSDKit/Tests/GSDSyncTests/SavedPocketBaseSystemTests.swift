import Foundation
import Testing
import GSDModel
import GSDStore
@testable import GSDSync
@testable import GSDWire

/// Opt-in localhost integration, provisioned by scripts/verify-saved-sync.mjs.
@MainActor
struct SavedPocketBaseSystemTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GSD_SAVED_PB_URL"] != nil))
    func webCreateNativeNotesReturnAndSaveAgainstRealPocketBase() async throws {
        let environment = ProcessInfo.processInfo.environment
        let baseURL = try #require(environment["GSD_SAVED_PB_URL"])
        let token = try #require(environment["GSD_SAVED_PB_TOKEN"])
        #expect(URL(string: baseURL)?.host == "127.0.0.1")
        guard URL(string: baseURL)?.host == "127.0.0.1" else { return }
        let owner = try #require(JWT.userId(token))
        let db = try AppDatabase.inMemory()
        let repo = GRDBTaskRepository(db)
        let queue = GRDBSyncQueueRepository(db)
        let defaults = UserDefaults(suiteName: "saved-pb-\(UUID().uuidString)")!
        let client = PocketBaseClient(baseURL: baseURL)
        let engine = SyncEngine(client: client, tasks: repo, queue: queue,
                                cursor: SyncCursor(defaults: defaults), deviceId: "ios-saved-test",
                                tokenProvider: { token }, throttleMs: 0)
        let store = TaskStore(repository: repo, smartViewRepository: GRDBSmartViewRepository(db),
                              archiveRepository: GRDBArchiveRepository(db), trashRepository: GRDBTrashRepository(db),
                              defaults: defaults, syncQueue: queue)
        _ = try await engine.pull(token: token, since: "1970-01-01T00:00:00.000Z")
        let original = try #require(try await repo.fetch(id: "native-saved-e2e"))
        #expect(original.isSaved && original.description == "Created by the web client")
        try await store.updateSavedNotes(id: original.id, notes: "Native annotation 😀")
        var pushed = try await engine.push(token: token, owner: owner)
        #expect(pushed.pushed == 1 && pushed.failed == 0)
        var remote = try #require(try await client.listTasks(updatedSince: "1970-01-01T00:00:00.000Z", token: token).first)
        #expect(remote.description == "Native annotation 😀" && !remote.savedAt.isEmpty)
        try await store.returnToMatrix(id: original.id, quadrant: .urgentImportant, dueDate: nil)
        pushed = try await engine.push(token: token, owner: owner)
        #expect(pushed.pushed == 1 && pushed.failed == 0)
        remote = try #require(try await client.listTasks(updatedSince: "1970-01-01T00:00:00.000Z", token: token).first)
        #expect(remote.savedAt.isEmpty && remote.urgent && remote.important)
        let returned = try #require(try await repo.fetch(id: original.id))
        _ = try await store.moveToSaved(returned)
        pushed = try await engine.push(token: token, owner: owner)
        #expect(pushed.pushed == 1 && pushed.failed == 0)
        #expect(try await queue.all().isEmpty)
    }
}
