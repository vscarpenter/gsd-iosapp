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
    private func makeStore(_ rec: RecordingReminderScheduler) throws -> TaskStore {
        let db = try AppDatabase.inMemory()
        let fixed = now
        nonisolated(unsafe) var idCount = 0
        return TaskStore(repository: GRDBTaskRepository(db),
                         smartViewRepository: GRDBSmartViewRepository(db),
                         archiveRepository: GRDBArchiveRepository(db),
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
}
