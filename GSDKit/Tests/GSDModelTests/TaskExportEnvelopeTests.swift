import Testing
import Foundation
@testable import GSDModel

/// The envelope must match the WEB client's backup shape exactly — its import schema is
/// strict about field names, and a mismatch is silent: the store simply never restores.
/// These tests pin the wire contract, not this app's internal spelling.
struct TaskExportEnvelopeTests {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func task(_ id: String) -> Task {
        Task(id: id, title: id, urgent: true, important: true, createdAt: epoch, updatedAt: epoch)
    }

    private func json(_ export: TaskExport) throws -> String {
        String(decoding: try TaskExport.encode(export), as: UTF8.self)
    }

    // MARK: version

    @Test func versionIsTheSemverStringTheWebWrites() throws {
        let export = TaskExport(tasks: [], exportedAt: epoch)
        #expect(export.version == "2.1.0")
        #expect(try json(export).contains("\"version\" : \"2.1.0\""))
    }

    @Test func decodesALegacyNumericVersion() throws {
        // Every build through iOS 2.2.0 wrote `version: 1`. Those backups must still open.
        let legacy = #"{"tasks":[],"exportedAt":"2023-11-14T22:13:20.000Z","version":1}"#
        let decoded = try TaskExport.decode(Data(legacy.utf8))
        #expect(decoded.version == "1")
    }

    @Test func decodesAStringVersion() throws {
        let payload = #"{"tasks":[],"exportedAt":"2023-11-14T22:13:20.000Z","version":"2.1.0"}"#
        #expect(try TaskExport.decode(Data(payload.utf8)).version == "2.1.0")
    }

    @Test func decodesAnAbsentVersionAsOne() throws {
        let payload = #"{"tasks":[],"exportedAt":"2023-11-14T22:13:20.000Z"}"#
        #expect(try TaskExport.decode(Data(payload.utf8)).version == "1")
    }

    // MARK: absent vs empty

    @Test func omitsEveryOptionalStoreWhenNotSupplied() throws {
        // An absent key means "says nothing about that store"; the importer must be able
        // to tell that apart from `[]`, which means "clear it".
        let out = try json(TaskExport(tasks: [task("a")], exportedAt: epoch))
        #expect(!out.contains("archivedTasks"))
        #expect(!out.contains("deletedTasks"))
        #expect(!out.contains("smartViews"))
        #expect(!out.contains("notificationSettings"))
        #expect(!out.contains("archiveSettings"))
        #expect(!out.contains("appPreferences"))
    }

    @Test func distinguishesAnEmptyArchiveFromAnAbsentOne() throws {
        let empty = try TaskExport.decode(try TaskExport.encode(
            TaskExport(tasks: [], exportedAt: epoch, archivedTasks: [])))
        #expect(empty.archivedTasks == [])

        let absent = try TaskExport.decode(try TaskExport.encode(
            TaskExport(tasks: [], exportedAt: epoch)))
        #expect(absent.archivedTasks == nil)
    }

    // MARK: archived + deleted rows are flat

    @Test func archivedTaskEncodesFlatWithArchivedAt() throws {
        let archived = ArchivedTask(task: task("a"), stampedAt: epoch)
        let out = try json(TaskExport(tasks: [], exportedAt: epoch, archivedTasks: [archived]))
        // The stamp sits beside the task's own keys, not nested under "task".
        #expect(out.contains("\"archivedAt\""))
        #expect(!out.contains("\"task\" :"))
        #expect(out.contains("\"title\" : \"a\""))
    }

    @Test func deletedTaskEncodesWithDeletedAtNotArchivedAt() throws {
        let trashed = ArchivedTask(task: task("a"), stampedAt: epoch, stampKey: .deletedAt)
        let out = try json(TaskExport(tasks: [], exportedAt: epoch, deletedTasks: [trashed]))
        #expect(out.contains("\"deletedAt\""))
        #expect(!out.contains("\"archivedAt\""))
    }

    @Test func roundTripsArchivedAndDeletedRows() throws {
        let original = TaskExport(
            tasks: [], exportedAt: epoch,
            archivedTasks: [ArchivedTask(task: task("arch"), stampedAt: epoch)],
            deletedTasks: [ArchivedTask(task: task("gone"), stampedAt: epoch, stampKey: .deletedAt)])
        let decoded = try TaskExport.decode(try TaskExport.encode(original))
        #expect(decoded.archivedTasks?.first?.task.id == "arch")
        #expect(decoded.archivedTasks?.first?.stampKey == .archivedAt)
        #expect(decoded.deletedTasks?.first?.task.id == "gone")
        #expect(decoded.deletedTasks?.first?.stampKey == .deletedAt)
        #expect(decoded.deletedTasks?.first?.stampedAt == epoch)
    }

    // MARK: settings singletons use the web's field names

    @Test func archiveSettingsUseTheWebsSpelling() throws {
        // This app calls these `autoEnabled` and `afterDays`; the web does not, and its
        // schema requires `enabled` + `archiveAfterDays`.
        let wire = ArchiveSettingsWire(autoEnabled: true, afterDays: 60)
        let out = try json(TaskExport(tasks: [], exportedAt: epoch, archiveSettings: wire))
        #expect(out.contains("\"archiveAfterDays\" : 60"))
        #expect(out.contains("\"enabled\" : true"))
        #expect(out.contains("\"id\" : \"settings\""))
        #expect(!out.contains("autoEnabled"))
        #expect(!out.contains("afterDays\" :"))
    }

    @Test func notificationSettingsCarryIdAndUpdatedAt() throws {
        // Both are required by the web's schema and unused here.
        let settings = NotificationSettings(enabled: true, defaultReminder: 30,
                                            soundEnabled: false, quietHoursStart: "22:00",
                                            quietHoursEnd: "07:00", permissionAsked: true)
        let wire = NotificationSettingsWire(settings, updatedAt: epoch)
        let out = try json(TaskExport(tasks: [], exportedAt: epoch, notificationSettings: wire))
        #expect(out.contains("\"id\" : \"settings\""))
        #expect(out.contains("\"updatedAt\""))
        #expect(out.contains("\"defaultReminder\" : 30"))
        #expect(out.contains("\"quietHoursStart\" : \"22:00\""))
    }

    @Test func notificationSettingsRoundTripBackToTheModel() throws {
        let settings = NotificationSettings(enabled: false, defaultReminder: 120,
                                            soundEnabled: true, quietHoursStart: "23:30",
                                            quietHoursEnd: "06:15", permissionAsked: true)
        let decoded = try TaskExport.decode(try TaskExport.encode(
            TaskExport(tasks: [], exportedAt: epoch,
                       notificationSettings: NotificationSettingsWire(settings, updatedAt: epoch))))
        #expect(decoded.notificationSettings?.settings == settings)
    }

    @Test func appPreferencesWriteSmartViewsEnabledForTheWeb() throws {
        // This app has no such toggle; the web's schema requires the key.
        let wire = AppPreferencesWire(pinnedSmartViewIds: ["a", "b"], maxPinnedViews: 5)
        let out = try json(TaskExport(tasks: [], exportedAt: epoch, appPreferences: wire))
        #expect(out.contains("\"smartViewsEnabled\" : true"))
        #expect(out.contains("\"id\" : \"preferences\""))
        #expect(out.contains("\"maxPinnedViews\" : 5"))
    }

    // MARK: smart views

    @Test func smartViewRoundTripsItsCriteria() throws {
        let criteria = FilterCriteria(quadrants: [.urgentImportant], status: .active,
                                      tags: ["work"], overdue: true,
                                      recurrence: [.daily], readyToWork: true)
        let view = SmartViewWire(id: "v1", name: "Mine", icon: "bolt",
                                 criteria: criteria, createdAt: epoch, updatedAt: epoch)
        let decoded = try TaskExport.decode(try TaskExport.encode(
            TaskExport(tasks: [], exportedAt: epoch, smartViews: [view])))
        #expect(decoded.smartViews?.first?.criteria == criteria)
        #expect(decoded.smartViews?.first?.isBuiltIn == false)
    }

    @Test func smartViewCriteriaUseTheSharedQuadrantAndRecurrenceSpellings() throws {
        let view = SmartViewWire(
            id: "v1", name: "Mine",
            criteria: FilterCriteria(quadrants: [.notUrgentImportant], recurrence: [.weekly]),
            createdAt: epoch, updatedAt: epoch)
        let out = try json(TaskExport(tasks: [], exportedAt: epoch, smartViews: [view]))
        #expect(out.contains("\"not-urgent-important\""))
        #expect(out.contains("\"weekly\""))
    }

    // MARK: unchanged guarantees

    @Test func stillWritesFractionalSecondsISO8601() throws {
        let out = try json(TaskExport(tasks: [], exportedAt: Date(timeIntervalSince1970: 0.5)))
        #expect(out.contains(".500Z"))
    }

    @Test func ignoresUnknownEnvelopeKeys() throws {
        let payload = #"{"tasks":[],"exportedAt":"2023-11-14T22:13:20.000Z","version":"2.1.0","futureStore":[1,2]}"#
        #expect(try TaskExport.decode(Data(payload.utf8)).tasks.isEmpty)
    }
}
