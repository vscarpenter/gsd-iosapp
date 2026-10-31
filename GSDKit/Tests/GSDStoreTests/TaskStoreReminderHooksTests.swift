import Testing
import Foundation
import GSDModel
@testable import GSDStore

/// Records every reminder call so the test can assert the store's §9.1 forwarding.
/// `@MainActor` because `TaskStore` is `@MainActor` and calls land there.
@MainActor
final class RecordingReminderScheduler: ReminderScheduling {
    enum Call: Equatable { case schedule(String), cancel(String), cancelAll, badge(Int), auth }
    var calls: [Call] = []
    nonisolated init() {}
    func schedule(_ task: Task) async { calls.append(.schedule(task.id)) }
    func cancel(taskID: String) async { calls.append(.cancel(taskID)) }
    func cancelAll() async { calls.append(.cancelAll) }
    func requestAuthorizationIfNeeded() async -> Bool { calls.append(.auth); return true }
    func setBadge(_ count: Int) async { calls.append(.badge(count)) }
    /// Schedule/cancel calls only (badge is asserted separately where it matters).
    var scheduleCancelCalls: [Call] { calls.filter { if case .badge = $0 { false } else if case .auth = $0 { false } else { true } } }
}

@MainActor
struct TaskStoreReminderHooksTests {
    private let now: Date = {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 9))!
    }()
    private func utc() -> Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }
    private func makeStore(_ rec: RecordingReminderScheduler, db: AppDatabase? = nil) throws -> TaskStore {
        let db = try db ?? AppDatabase.inMemory()
        let fixed = now
        nonisolated(unsafe) var idCount = 0
        return TaskStore(repository: GRDBTaskRepository(db),
                         smartViewRepository: GRDBSmartViewRepository(db),
                         archiveRepository: GRDBArchiveRepository(db),
                         trashRepository: GRDBTrashRepository(db),
                         defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!,
                         clock: { fixed },
                         newID: { idCount += 1; return "id-\(idCount)" },
                         calendar: utc(),
                         reminders: rec)
    }
    private func task(_ id: String, due: Date? = nil, recurrence: RecurrenceType = .none,
                      completed: Bool = false) -> Task {
        Task(id: id, title: id, urgent: false, important: false, completed: completed,
             completedAt: completed ? now : nil, createdAt: now, updatedAt: now,
             dueDate: due, recurrence: recurrence)
    }

    @Test func createSchedules() async throws {
        let rec = RecordingReminderScheduler()
        let store = try makeStore(rec)
        try await store.create(task("a", due: now.addingTimeInterval(3600)))
        #expect(rec.scheduleCancelCalls == [.schedule("a")])
    }
    @Test func saveReschedules() async throws {
        let rec = RecordingReminderScheduler()
        let store = try makeStore(rec)
        try await store.save(task("a", due: now.addingTimeInterval(3600)))
        #expect(rec.scheduleCancelCalls == [.schedule("a")])
    }
    @Test func completeCancelsAndReactivateSchedules() async throws {
        let rec = RecordingReminderScheduler()
        let store = try makeStore(rec)
        try await store.create(task("a", due: now.addingTimeInterval(3600)))      // schedule
        // toggleComplete reads the persisted row; persist it first via create above.
        try await store.toggleComplete(task("a", due: now.addingTimeInterval(3600)))   // → completed → cancel
        try await store.toggleComplete(task("a", due: now.addingTimeInterval(3600), completed: true)) // → active → schedule
        #expect(rec.scheduleCancelCalls == [.schedule("a"), .cancel("a"), .schedule("a")])
    }
    @Test func deleteCancels() async throws {
        let rec = RecordingReminderScheduler()
        let store = try makeStore(rec)
        try await store.delete(task("a"))
        #expect(rec.scheduleCancelCalls == [.cancel("a")])
    }
    @Test func snoozeReschedules() async throws {
        let rec = RecordingReminderScheduler()
        let store = try makeStore(rec)
        try await store.snooze(task("a", due: now.addingTimeInterval(3600)), by: .oneHour)
        #expect(rec.scheduleCancelCalls == [.schedule("a")])
    }
    @Test func completingRecurringSchedulesBothCancelAndSpawn() async throws {
        let rec = RecordingReminderScheduler()
        let store = try makeStore(rec)
        // A recurring task with a due date; toggleComplete cancels the original + schedules the spawn.
        try await store.create(task("r", due: now.addingTimeInterval(3600), recurrence: .daily)) // schedule "r"
        try await store.toggleComplete(task("r", due: now.addingTimeInterval(3600), recurrence: .daily))
        // → cancel "r"; the spawn (a fresh newID, here "id-1") is scheduled. Assert the SHAPE
        // (cancel original + schedule a new, different id) rather than hardcoding the spawn id,
        // since `newID()` is evaluated as a `spawnNext` argument on every toggleComplete call.
        #expect(rec.scheduleCancelCalls.contains(.schedule("r")))
        #expect(rec.scheduleCancelCalls.contains(.cancel("r")))
        let spawnSchedules = rec.scheduleCancelCalls.filter {
            if case .schedule(let id) = $0 { id != "r" } else { false }
        }
        #expect(spawnSchedules.count == 1)   // exactly one schedule for the spawned instance
    }
    @Test func resyncRemindersRebuildsOnlyEligibleTasks() async throws {
        let rec = RecordingReminderScheduler()
        let store = try makeStore(rec)
        store.start()
        try await store.create(task("due", due: now.addingTimeInterval(3600)))
        try await store.create(task("noDue"))
        try await store.create(task("done", due: now.addingTimeInterval(3600), completed: true))
        var muted = task("muted", due: now.addingTimeInterval(3600))
        muted.notificationEnabled = false
        try await store.create(muted)
        var waited = 0
        while store.tasks.count != 4 && waited < 200 {
            try await _Concurrency.Task.sleep(for: .milliseconds(10)); waited += 1
        }
        rec.calls = []
        await store.resyncReminders()
        #expect(rec.calls.first == .cancelAll)                       // wipe first…
        #expect(rec.scheduleCancelCalls == [.cancelAll, .schedule("due")])  // …then only the eligible task
        #expect(rec.calls.contains { if case .badge = $0 { true } else { false } })  // badge refreshed
    }

    @Test func resyncSchedulesOnlyTheSoonestSixtyInFireOrder() async throws {
        // B-37: iOS keeps 64 pending requests and does not document which survive, so the
        // store picks. 70 tasks, shuffled; the soonest 60 by fire time are scheduled, in order.
        let rec = RecordingReminderScheduler()
        let store = try makeStore(rec)
        store.start()
        // Quiet hours (seeded 22:00-07:00) would defer some fires and reorder them; this test is
        // about the cap, so take them out of the picture.
        var settings = store.notificationSettings
        settings.quietHoursStart = nil; settings.quietHoursEnd = nil
        store.notificationSettings = settings
        let hours = Array(1...70).shuffled()
        // Half past the hour: a due time of exactly local midnight is an all-day task, which fires at 09:00.
        for h in hours { try await store.create(task("t\(h)", due: now.addingTimeInterval(Double(h) * 3600 + 1800))) }
        try await store.create(task("past", due: now.addingTimeInterval(-3600)))                   // no future fire
        try await store.create(task("done", due: now.addingTimeInterval(1800), completed: true))   // no reminder
        var waited = 0
        while store.tasks.count != 72 && waited < 400 {
            try await _Concurrency.Task.sleep(for: .milliseconds(10)); waited += 1
        }
        rec.calls = []
        await store.resyncReminders()
        let scheduled = rec.scheduleCancelCalls.compactMap { call -> String? in
            if case .schedule(let id) = call { id } else { nil }
        }
        #expect(scheduled == (1...60).map { "t\($0)" })
    }

    @Test func resyncBreaksEqualFireTimesById() async throws {
        let rec = RecordingReminderScheduler()
        let store = try makeStore(rec)
        store.start()
        let due = now.addingTimeInterval(7200)
        for n in (0..<62).shuffled() { try await store.create(task("c\(String(format: "%02d", n))", due: due)) }
        var waited = 0
        while store.tasks.count != 62 && waited < 400 {
            try await _Concurrency.Task.sleep(for: .milliseconds(10)); waited += 1
        }
        rec.calls = []
        await store.resyncReminders()
        let expected = (0..<60).map { RecordingReminderScheduler.Call.schedule("c\(String(format: "%02d", $0))") }
        #expect(rec.scheduleCancelCalls == [.cancelAll] + expected)
    }

    // B-07, foreground half: sync moves the row straight through the repository, so no §9.1 hook runs.
    // The observer still fires `onTasksChanged`, which the App debounces into this resync.
    @Test func aTaskSyncAbandonsToTrashNotifiesTheObserverAndLeavesTheResync() async throws {
        let db = try AppDatabase.inMemory()
        let rec = RecordingReminderScheduler()
        let store = try makeStore(rec, db: db)
        nonisolated(unsafe) var changes = 0
        store.onTasksChanged = { changes += 1 }
        store.start()
        try await GRDBTaskRepository(db).upsert(task("a", due: now.addingTimeInterval(3600)))
        try await GRDBTaskRepository(db).upsert(task("b", due: now.addingTimeInterval(3600)))
        var waited = 0
        while store.tasks.count != 2 && waited < 200 {
            try await _Concurrency.Task.sleep(for: .milliseconds(10)); waited += 1
        }
        let changesBefore = changes

        let moved = try await GRDBTombstoneRepository(db).abandonToTrash(id: "a", at: now)
        waited = 0
        while store.tasks.count != 1 && waited < 200 {
            try await _Concurrency.Task.sleep(for: .milliseconds(10)); waited += 1
        }
        rec.calls = []
        await store.resyncReminders()

        #expect(moved)
        #expect(changes > changesBefore)
        #expect(rec.scheduleCancelCalls == [.cancelAll, .schedule("b")])
    }

    @Test func archiveCancelsReminder() async throws {
        let rec = RecordingReminderScheduler()
        let store = try makeStore(rec)
        try await store.create(task("a", due: now.addingTimeInterval(3600)))   // schedule
        try await store.archive(task("a", due: now.addingTimeInterval(3600)))
        #expect(rec.scheduleCancelCalls == [.schedule("a"), .cancel("a")])     // no ghost reminder
    }
    @Test func eraseAllDataCancelsEveryReminderAndZeroesBadge() async throws {
        let rec = RecordingReminderScheduler()
        let store = try makeStore(rec)
        try await store.create(task("a", due: now.addingTimeInterval(3600)))
        try await store.eraseAllData()
        #expect(rec.calls.contains(.cancelAll))
        #expect(rec.calls.contains(.badge(0)))
    }
    @Test func refreshBadgeForwardsComputedCount() async throws {
        let rec = RecordingReminderScheduler()
        let store = try makeStore(rec)
        store.start()
        // Two due-today/overdue tasks + one future → badge 2.
        try await store.create(task("a", due: now.addingTimeInterval(-3600)))   // overdue
        try await store.create(task("b", due: now))                              // due today
        try await store.create(task("c", due: now.addingTimeInterval(7 * 86_400))) // future
        var waited = 0
        while store.tasks.count != 3 && waited < 200 {
            try await _Concurrency.Task.sleep(for: .milliseconds(10)); waited += 1
        }
        await store.refreshBadge()
        #expect(rec.calls.contains(.badge(2)))
    }
}
