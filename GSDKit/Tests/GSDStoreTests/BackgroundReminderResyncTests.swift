import Testing
import Foundation
import GSDModel
@testable import GSDStore

/// A task repository whose reads fail, for the resync that can't see the store.
private struct UnreadableTaskRepository: TaskRepository {
    struct ReadFailed: Error {}
    func upsert(_ task: Task) async throws {}
    func fetchAll() async throws -> [Task] { throw ReadFailed() }
    func fetch(id: String) async throws -> Task? { throw ReadFailed() }
    func delete(id: String) async throws {}
    func replaceAll(_ tasks: [Task]) async throws {}
    func observeAll() -> AsyncThrowingStream<[Task], Error> { AsyncThrowingStream { $0.finish() } }
}

/// IOS-CAP-BG: background refresh resyncs reminders, and it can run before any scene has started
/// the store's observation, so `tasks` may still be empty there.
@MainActor
struct BackgroundReminderResyncTests {
    private let now: Date = {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 9))!
    }()

    private func makeStore(_ rec: RecordingReminderScheduler, repository: any TaskRepository, db: AppDatabase) -> TaskStore {
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
        let fixed = now
        return TaskStore(repository: repository,
                         smartViewRepository: GRDBSmartViewRepository(db),
                         archiveRepository: GRDBArchiveRepository(db),
                         trashRepository: GRDBTrashRepository(db),
                         defaults: UserDefaults(suiteName: "bg-resync-\(UUID().uuidString)")!,
                         clock: { fixed }, calendar: utc, reminders: rec)
    }

    @Test func aResyncBeforeObservationStartsSchedulesFromTheStore() async throws {
        let db = try AppDatabase.inMemory()
        let repo = GRDBTaskRepository(db)
        let rec = RecordingReminderScheduler()
        let store = makeStore(rec, repository: repo, db: db)
        // Written straight to the repository, as a background pull does, with no `store.start()`.
        try await repo.upsert(Task(id: "due", title: "Call the venue", urgent: true, important: true,
                                   createdAt: now, updatedAt: now, dueDate: now.addingTimeInterval(3 * 3600 + 1800)))

        await store.resyncReminders()

        #expect(rec.scheduleCancelCalls == [.cancelAll, .schedule("due")])
    }

    @Test func aResyncThatCantReadTheStoreKeepsThePendingReminders() async throws {
        let rec = RecordingReminderScheduler()
        let store = makeStore(rec, repository: UnreadableTaskRepository(), db: try AppDatabase.inMemory())

        await store.resyncReminders()

        #expect(!rec.calls.contains(.cancelAll))
    }
}
