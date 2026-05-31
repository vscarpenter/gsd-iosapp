import Testing
import Foundation
import GSDModel
@testable import GSDStore

@MainActor
struct NotificationSettingsStoreTests {
    private func makeStore() throws -> TaskStore {
        let db = try AppDatabase.inMemory()
        return TaskStore(repository: GRDBTaskRepository(db),
                         smartViewRepository: GRDBSmartViewRepository(db),
                         archiveRepository: GRDBArchiveRepository(db),
                         defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!)
    }

    @Test func defaultsMatchSpec() throws {
        let s = try makeStore().notificationSettings
        #expect(s.enabled == true && s.defaultReminder == 15 && s.soundEnabled == true)
        #expect(s.quietHoursStart == nil && s.quietHoursEnd == nil && s.permissionAsked == false)
    }
    @Test func roundTripsThroughDefaults() throws {
        let store = try makeStore()
        store.notificationSettings = NotificationSettings(enabled: false, defaultReminder: 60,
            soundEnabled: false, quietHoursStart: "22:00", quietHoursEnd: "07:00", permissionAsked: true)
        let back = store.notificationSettings
        #expect(back.enabled == false && back.defaultReminder == 60 && back.soundEnabled == false)
        #expect(back.quietHoursStart == "22:00" && back.quietHoursEnd == "07:00" && back.permissionAsked == true)
    }
    @Test func clearingQuietHoursPersistsNil() throws {
        let store = try makeStore()
        store.notificationSettings = NotificationSettings(quietHoursStart: "22:00", quietHoursEnd: "07:00")
        store.notificationSettings = NotificationSettings(quietHoursStart: nil, quietHoursEnd: nil)
        #expect(store.notificationSettings.quietHoursStart == nil)
        #expect(store.notificationSettings.quietHoursEnd == nil)
    }
    @Test func invalidDefaultReminderClampsTo15() throws {
        let store = try makeStore()
        store.notificationSettings = NotificationSettings(defaultReminder: 999)   // not an allowed value
        #expect(store.notificationSettings.defaultReminder == 15)
    }
}
