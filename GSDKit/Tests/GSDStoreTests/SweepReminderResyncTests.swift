import Testing
import Foundation
import GSDModel
@testable import GSDStore

/// spec-weekly-sweep section 6: a task reminder resync must not drop the sweep reminder, and a
/// local erase must clear it.
@MainActor
struct SweepReminderResyncTests {
    final class Recorder: ReminderScheduling, @unchecked Sendable {
        private(set) var calls: [String] = []
        func schedule(_ task: Task) async { calls.append("schedule") }
        func cancel(taskID: String) async { calls.append("cancel") }
        func cancelAll() async { calls.append("cancelAll") }
        func requestAuthorizationIfNeeded() async -> Bool { false }
        func setBadge(_ count: Int) async {}
        func rescheduleSweepReminder() async { calls.append("sweep") }
    }

    private func makeStore(_ recorder: Recorder, defaults: UserDefaults) throws -> TaskStore {
        let db = try AppDatabase.inMemory()
        return TaskStore(repository: GRDBTaskRepository(db), smartViewRepository: GRDBSmartViewRepository(db),
                         archiveRepository: GRDBArchiveRepository(db), trashRepository: GRDBTrashRepository(db),
                         defaults: defaults, reminders: recorder)
    }

    @Test func aTaskReminderResyncKeepsTheSweepReminder() async throws {
        let recorder = Recorder()
        let store = try makeStore(recorder, defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!)
        await store.resyncReminders()
        let cancel = try #require(recorder.calls.firstIndex(of: "cancelAll"))
        let sweep = try #require(recorder.calls.firstIndex(of: "sweep"))
        #expect(sweep > cancel)   // scheduled again after the cancel that removed it
    }

    @Test func aLocalEraseClearsTheSweepReminder() async throws {
        let recorder = Recorder()
        let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        WeeklySweepSettings.setReminder(WeeklySweepSettings.defaultReminder, in: defaults)
        let store = try makeStore(recorder, defaults: defaults)
        try await store.eraseAllData()
        #expect(recorder.calls.contains("cancelAll"))                 // removes the pending request
        #expect(!recorder.calls.contains("sweep"))                    // and nothing schedules it again
        #expect(WeeklySweepSettings.reminder(from: defaults) == .off) // the stored setting is gone
    }

    @Test func calendarWeekdayMapsIsoToCalendarNumbering() {
        func w(_ iso: Int) -> Int { WeeklySweep.Reminder(enabled: true, weekday: iso, hour: 9, minute: 0).calendarWeekday }
        #expect(w(7) == 1)   // Sunday
        #expect(w(1) == 2)   // Monday
        #expect(w(6) == 7)   // Saturday
    }
}
