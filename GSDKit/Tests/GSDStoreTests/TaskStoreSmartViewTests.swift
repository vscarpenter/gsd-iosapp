import Testing
import Foundation
import GSDModel
@testable import GSDStore

@MainActor
struct TaskStoreSmartViewTests {
    private let t0 = Date(timeIntervalSince1970: 0)
    private func makeStore() throws -> TaskStore {
        let db = try AppDatabase.inMemory()
        let suite = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        return TaskStore(repository: GRDBTaskRepository(db),
                         smartViewRepository: GRDBSmartViewRepository(db),
                         archiveRepository: GRDBArchiveRepository(db, now: { Date(timeIntervalSince1970: 0) }),
                         defaults: suite,
                         clock: { Date(timeIntervalSince1970: 1000) },
                         newID: { "sv-fixed" },
                         calendar: .current)
    }
    private func waitForCustomViews(_ store: TaskStore, count: Int) async throws {
        store.start()
        var waited = 0
        while store.customViews.count != count && waited < 100 {
            try await _Concurrency.Task.sleep(for: .milliseconds(10)); waited += 1
        }
    }

    @Test func createPersistsCustomViewWithGeneratedIdAndStamps() async throws {
        let store = try makeStore()
        store.start()
        try await store.createView(name: "Mine", icon: "star", criteria: FilterCriteria(status: .active))
        try await waitForCustomViews(store, count: 1)
        #expect(store.customViews.first?.id == "sv-fixed")
        #expect(store.customViews.first?.isBuiltIn == false)
    }
    @Test func allViewsOrdersPinnedThenBuiltInsThenCustom() async throws {
        let store = try makeStore()
        try await store.createView(name: "Custom A", icon: "star", criteria: FilterCriteria())
        try await waitForCustomViews(store, count: 1)
        store.pin("overdue")                       // pin a built-in
        let ids = store.allViews.map(\.id)
        #expect(ids.first == "overdue")            // pinned surfaces first
        #expect(ids.contains("today-focus"))       // built-ins present
        #expect(ids.last == "sv-fixed")            // custom last
        #expect(ids.filter { $0 == "overdue" }.count == 1)  // pinned NOT duplicated in built-in section
    }
    @Test func pinPersistsToDefaultsAndCapsAtFive() async throws {
        let store = try makeStore()
        for id in ["a", "b", "c", "d", "e", "f"] { store.pin(id) }
        #expect(store.pinnedSmartViewIds == ["a", "b", "c", "d", "e"])
        store.unpin("a")
        #expect(store.pinnedSmartViewIds == ["b", "c", "d", "e"])
    }
    @Test func deleteRemovesCustomViewAndUnpins() async throws {
        let store = try makeStore()
        try await store.createView(name: "Mine", icon: "star", criteria: FilterCriteria())
        try await waitForCustomViews(store, count: 1)
        store.pin("sv-fixed")
        try await store.deleteView(id: "sv-fixed")
        try await waitForCustomViews(store, count: 0)
        #expect(store.pinnedSmartViewIds.contains("sv-fixed") == false)  // delete also unpins
    }
    @Test func updateViewRewritesCriteria() async throws {
        let store = try makeStore()
        try await store.createView(name: "Mine", icon: "star", criteria: FilterCriteria(status: .active))
        try await waitForCustomViews(store, count: 1)
        let edited = SmartView(id: "sv-fixed", name: "Renamed", icon: "bolt",
                               criteria: FilterCriteria(status: .completed), isBuiltIn: false)
        try await store.updateView(edited)
        // observer re-emits; poll for the rename
        var waited = 0
        while store.customViews.first?.name != "Renamed" && waited < 100 {
            try await _Concurrency.Task.sleep(for: .milliseconds(10)); waited += 1
        }
        #expect(store.customViews.first?.name == "Renamed")
        #expect(store.customViews.first?.criteria.status == .completed)
    }
}
