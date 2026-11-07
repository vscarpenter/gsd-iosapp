import Testing
import Foundation
import GSDModel
@testable import GSDStore

struct WeeklySweepSettingsTests {
    private func freshDefaults() -> UserDefaults { UserDefaults(suiteName: "test-\(UUID().uuidString)")! }

    @Test func startsNeverSweptWithTheReminderOff() {
        let d = freshDefaults()
        #expect(WeeklySweepSettings.lastSweptAt(from: d) == nil)
        #expect(WeeklySweepSettings.reminder(from: d) == .off)
    }

    @Test func turningTheReminderOnStartsAtSundayNine() {
        #expect(WeeklySweepSettings.defaultReminder
                == WeeklySweep.Reminder(enabled: true, weekday: 7, hour: 9, minute: 0))
    }

    @Test func lastSweptRoundTrips() {
        let d = freshDefaults()
        let stamp = Date(timeIntervalSince1970: 1_800_000_000)
        WeeklySweepSettings.stampSwept(at: stamp, in: d)
        #expect(WeeklySweepSettings.lastSweptAt(from: d) == stamp)
    }

    @Test func reminderRoundTrips() {
        let d = freshDefaults()
        let reminder = WeeklySweep.Reminder(enabled: true, weekday: 1, hour: 7, minute: 30)
        WeeklySweepSettings.setReminder(reminder, in: d)
        #expect(WeeklySweepSettings.reminder(from: d) == reminder)
    }

    @Test(arguments: [[1, 8, 9, 0], [1, 0, 9, 0], [1, 7, 24, 0], [1, 7, 9, 60], [2, 7, 9, 0], [1, 7, 9]])
    func anUnknownStoredReminderFallsBackToOff(_ stored: [Int]) {
        let d = freshDefaults()
        d.set(stored, forKey: AppGroupDefaults.Key.weeklySweepReminder)
        #expect(WeeklySweepSettings.reminder(from: d) == .off)
    }

    @Test func aWrongTypeFallsBackToOff() {
        let d = freshDefaults()
        d.set("sunday", forKey: AppGroupDefaults.Key.weeklySweepReminder)
        #expect(WeeklySweepSettings.reminder(from: d) == .off)
    }

    @Test func resetClearsBoth() {
        let d = freshDefaults()
        WeeklySweepSettings.stampSwept(at: Date(), in: d)
        WeeklySweepSettings.setReminder(WeeklySweepSettings.defaultReminder, in: d)
        WeeklySweepSettings.reset(in: d)
        #expect(WeeklySweepSettings.lastSweptAt(from: d) == nil)
        #expect(WeeklySweepSettings.reminder(from: d) == .off)
    }

    @MainActor @Test func eraseAllDataClearsLastSweptAndTheReminder() async throws {
        let db = try AppDatabase.inMemory()
        let defaults = freshDefaults()
        WeeklySweepSettings.stampSwept(at: Date(), in: defaults)
        WeeklySweepSettings.setReminder(WeeklySweepSettings.defaultReminder, in: defaults)
        let store = TaskStore(repository: GRDBTaskRepository(db),
                              smartViewRepository: GRDBSmartViewRepository(db),
                              archiveRepository: GRDBArchiveRepository(db),
                              trashRepository: GRDBTrashRepository(db),
                              defaults: defaults,
                              clock: { Date(timeIntervalSince1970: 1000) })
        try await store.eraseAllData()
        #expect(WeeklySweepSettings.lastSweptAt(from: defaults) == nil)
        #expect(WeeklySweepSettings.reminder(from: defaults) == .off)
    }
}
