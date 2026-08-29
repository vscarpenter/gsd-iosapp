import Testing
import Foundation
import GSDModel
@testable import GSDStore

/// The test that proves the cross-platform backup path actually works.
///
/// It reads a REAL web-client export — the same fixture file the web repo's suite reads,
/// copied byte-for-byte — restores it here, and then re-exports. Both halves matter: the
/// first catches a shape this app cannot read, the second catches a shape the web cannot
/// read back. Nothing in either suite alone would have caught the original bug, because
/// each client was internally consistent and only disagreed with the other.
@MainActor
struct CrossPlatformBackupTests {
    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }()
    private let now = Date(timeIntervalSince1970: 1_787_054_400)   // 2026-08-28T12:00:00Z

    private func makeStore() throws -> TaskStore {
        let db = try AppDatabase.inMemory()
        let fixed = now
        return TaskStore(repository: GRDBTaskRepository(db, now: { fixed }),
                         smartViewRepository: GRDBSmartViewRepository(db),
                         archiveRepository: GRDBArchiveRepository(db, now: { fixed }),
                         trashRepository: GRDBTrashRepository(db, now: { fixed }),
                         defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!,
                         clock: { fixed }, newID: { "id" }, calendar: cal,
                         syncQueue: GRDBSyncQueueRepository(db))
    }

    private func webBackup() throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "web-backup-2.1.0",
                                                 withExtension: "json",
                                                 subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private func waitForTasks(_ store: TaskStore, count: Int) async throws {
        store.start(); var w = 0
        while store.tasks.count != count && w < 100 {
            try await _Concurrency.Task.sleep(for: .milliseconds(10)); w += 1
        }
    }

    // MARK: reading the web's backup

    @Test func aWebBackupParsesAtAll() throws {
        // The original failure was the mirror of this: the web refused an iOS backup
        // outright because `version` was a number rather than a string.
        let decoded = try TaskExport.decode(try webBackup())
        #expect(decoded.version == "2.1.0")
        #expect(decoded.tasks.count == 2)
    }

    @Test func restoringAWebBackupBringsBackEveryStore() async throws {
        let store = try makeStore()
        try await store.importTasks(try webBackup(), mode: .replace)
        try await waitForTasks(store, count: 2)

        #expect(Set(store.tasks.map(\.id)) == ["web-task-1", "web-task-2"])

        // The five stores that were silently dropped before this fix.
        let archived = try await store.archivedTasksStamped()
        #expect(archived.map(\.task.id) == ["web-arch-1"])
        #expect(try await store.trashedTasks().map(\.task.id) == ["web-trash-1"])
        #expect(store.notificationSettings.defaultReminder == 120)
        #expect(store.notificationSettings.quietHoursStart == "22:00")
        #expect(store.notificationSettings.soundEnabled == false)
        #expect(store.archiveSettings.autoEnabled == true)
        #expect(store.archiveSettings.afterDays == 60)
        #expect(store.pinnedSmartViewIds == ["custom-view-1"])
    }

    @Test func restoringAWebBackupBringsBackTheCustomSmartView() async throws {
        let store = try makeStore()
        try await store.importTasks(try webBackup(), mode: .replace)

        store.start()   // the smart-view observer is what populates `customViews`
        var waited = 0
        while store.customViews.isEmpty && waited < 100 {
            try await _Concurrency.Task.sleep(for: .milliseconds(10)); waited += 1
        }

        let view = try #require(store.customViews.first)
        #expect(view.id == "custom-view-1")
        #expect(view.name == "Overdue work")
        #expect(view.isBuiltIn == false)
        #expect(view.criteria.overdue == true)
        #expect(view.criteria.tags == ["work"])
        #expect(view.criteria.quadrants == [.urgentImportant])
        #expect(view.criteria.recurrence == [.weekly])
    }

    @Test func restoringAWebBackupPreservesTaskDetail() async throws {
        let store = try makeStore()
        try await store.importTasks(try webBackup(), mode: .replace)
        try await waitForTasks(store, count: 2)

        let task = try #require(store.tasks.first { $0.id == "web-task-1" })
        #expect(task.title == "Ship the parity fixes")
        #expect(task.tags == ["work", "parity"])
        #expect(task.subtasks.count == 2)
        #expect(task.subtasks.first?.completed == true)
        #expect(task.recurrence == .weekly)
        #expect(task.notifyBefore == 30)
        #expect(task.estimatedMinutes == 120)
        #expect(task.timeEntries.count == 1)
        #expect(task.dueDate != nil)

        let blocked = try #require(store.tasks.first { $0.id == "web-task-2" })
        #expect(blocked.dependencies == ["web-task-1"])
    }

    @Test func theArchivedRowKeepsItsOriginalArchivedAt() async throws {
        // Re-stamping on restore would reset every archived task's age.
        let store = try makeStore()
        try await store.importTasks(try webBackup(), mode: .replace)
        let archived = try await store.archivedTasksStamped()
        let expected = iso("2026-06-01T10:00:00.000Z")
        #expect(archived.first?.stampedAt == expected)
    }

    @Test func theTrashedRowKeepsItsOriginalDeletedAt() async throws {
        // Re-stamping would hand the user back a full 30 days they had already spent.
        let store = try makeStore()
        try await store.importTasks(try webBackup(), mode: .replace)
        let trashed = try await store.trashedTasks()
        let expected = iso("2026-08-27T09:00:00.000Z")
        #expect(trashed.first?.stampedAt == expected)
        #expect(trashed.first?.stampKey == .deletedAt)
    }

    // MARK: writing a backup the web can read

    @Test func reExportingProducesTheWebsEnvelopeShape() async throws {
        let store = try makeStore()
        try await store.importTasks(try webBackup(), mode: .replace)
        try await waitForTasks(store, count: 2)

        let out = try await store.exportJSON()
        let object = try #require(try JSONSerialization.jsonObject(with: out) as? [String: Any])

        // The web's Zod schema requires a string version and these exact key names.
        #expect(object["version"] as? String == "2.1.0")
        #expect(object["exportedAt"] is String)
        #expect((object["tasks"] as? [Any])?.count == 2)
        #expect((object["archivedTasks"] as? [Any])?.count == 1)
        #expect((object["deletedTasks"] as? [Any])?.count == 1)

        let archiveSettings = try #require(object["archiveSettings"] as? [String: Any])
        #expect(archiveSettings["archiveAfterDays"] as? Int == 60)
        #expect(archiveSettings["enabled"] as? Bool == true)
        #expect(archiveSettings["id"] as? String == "settings")

        let notification = try #require(object["notificationSettings"] as? [String: Any])
        #expect(notification["defaultReminder"] as? Int == 120)
        #expect(notification["updatedAt"] is String)

        let prefs = try #require(object["appPreferences"] as? [String: Any])
        #expect(prefs["pinnedSmartViewIds"] as? [String] == ["custom-view-1"])
    }

    @Test func aFullRoundTripLosesNothing() async throws {
        let store = try makeStore()
        try await store.importTasks(try webBackup(), mode: .replace)
        try await waitForTasks(store, count: 2)
        let reExported = try await store.exportJSON()

        // Restore our own output into a fresh store — anything the writer drops shows up
        // here as a missing row rather than as a subtly different byte.
        let second = try makeStore()
        try await second.importTasks(reExported, mode: .replace)
        try await waitForTasks(second, count: 2)

        #expect(Set(second.tasks.map(\.id)) == ["web-task-1", "web-task-2"])
        #expect(try await second.archivedTasksStamped().count == 1)
        #expect(try await second.trashedTasks().count == 1)
        #expect(second.archiveSettings.afterDays == 60)
        #expect(second.notificationSettings.defaultReminder == 120)
    }

    // MARK: the legacy shape this app used to write

    @Test func aLegacyTasksOnlyBackupStillRestoresAndLeavesOtherStoresAlone() async throws {
        let store = try makeStore()
        try await store.importTasks(try webBackup(), mode: .replace)
        try await waitForTasks(store, count: 2)

        // What every build through 2.2.0 wrote: tasks, and a numeric version.
        let legacy = #"{"tasks":[],"exportedAt":"2026-08-28T12:00:00.000Z","version":1}"#
        try await store.importTasks(Data(legacy.utf8), mode: .replace)

        // Silence about a store must not be read as "clear it" — the same rule the web's
        // ADR 0014 states for a 1.0.0 payload.
        #expect(try await store.archivedTasksStamped().count == 1)
        #expect(try await store.trashedTasks().count == 1)
        #expect(store.archiveSettings.afterDays == 60)
    }
}

/// Fresh instance per call — `ISO8601DateFormatter` is not `Sendable`, so a shared static
/// trips strict concurrency. Matches the pattern `TaskExport` uses for the same reason.
private func iso(_ string: String) -> Date? {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.date(from: string)
}
