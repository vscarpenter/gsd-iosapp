import Foundation
import Observation
import GSDModel

/// Snooze durations (product spec §6.7). `.custom` supports arbitrary intervals
/// (clamped to `FieldLimits.maxSnoozeInterval`).
public enum SnoozePreset: Equatable, Sendable {
    case fifteenMinutes, thirtyMinutes, oneHour, threeHours, tomorrow, nextWeek
    case custom(TimeInterval)

    public var interval: TimeInterval {
        switch self {
        case .fifteenMinutes: 15 * 60
        case .thirtyMinutes:  30 * 60
        case .oneHour:        60 * 60
        case .threeHours:     3 * 60 * 60
        case .tomorrow:       24 * 60 * 60
        case .nextWeek:       7 * 24 * 60 * 60
        case .custom(let seconds): seconds
        }
    }
}

/// The single mutation path and observable task snapshot for the UI. Bridges
/// `TaskRepository.observeAll()` into `tasks`, and stamps `updatedAt` (via an
/// injected clock) on every PRIMARY mutation — satisfying the §3.3 invariant at
/// the use-case layer (the repository only stamps its own cascade side-effects).
@MainActor
@Observable
public final class TaskStore {
    public private(set) var tasks: [Task] = []

    private let repository: any TaskRepository
    private let clock: @Sendable () -> Date
    private let newID: @Sendable () -> String
    private let calendar: Calendar
    // nonisolated(unsafe) so deinit can cancel it without a MainActor hop.
    nonisolated(unsafe) private var observerTask: _Concurrency.Task<Void, Never>?

    public init(
        repository: any TaskRepository,
        clock: @escaping @Sendable () -> Date = { Date() },
        newID: @escaping @Sendable () -> String = { IDGenerator.generate(size: IDGenerator.Size.task) },
        calendar: Calendar = .current
    ) {
        self.repository = repository
        self.clock = clock
        self.newID = newID
        self.calendar = calendar
    }

    /// Begin observing the repository. Idempotent; call once from the app root.
    public func start() {
        guard observerTask == nil else { return }
        let stream = repository.observeAll()
        observerTask = _Concurrency.Task { [weak self] in
            do {
                for try await snapshot in stream { self?.tasks = snapshot }
            } catch {
                // Observation ended with an error; keep the last snapshot.
            }
        }
    }

    deinit { observerTask?.cancel() }

    // MARK: Mutations (all stamp updatedAt via the injected clock)

    public func add(_ parsed: ParsedCapture, override: Quadrant? = nil) async throws {
        let now = clock()
        let task = Task(
            id: newID(), title: parsed.title,
            description: parsed.descriptionAdditions.joined(separator: "\n"),
            urgent: override?.isUrgent ?? parsed.urgent,
            important: override?.isImportant ?? parsed.important,
            createdAt: now, updatedAt: now, tags: parsed.tags
        )
        try TaskValidator.validate(task)
        try await repository.upsert(task)
    }

    public func create(_ task: Task) async throws {
        var t = task
        let now = clock()
        t.createdAt = now
        t.updatedAt = now
        try TaskValidator.validate(t)
        try await repository.upsert(t)
    }

    public func save(_ task: Task) async throws {
        var t = task; t.updatedAt = clock()
        try TaskValidator.validate(t)
        try await repository.upsert(t)
    }

    public func toggleComplete(_ task: Task) async throws {
        var t = task
        let now = clock()
        let willComplete = !t.completed
        t.completed = willComplete
        t.completedAt = willComplete ? now : nil
        t.updatedAt = now
        try await repository.upsert(t)

        // Completing a recurring task spawns the next instance (product spec §6.5).
        guard willComplete,
              let next = RecurrenceEngine.spawnNext(from: t, now: now, newID: newID(), calendar: calendar)
        else { return }
        try await repository.upsert(next)
    }

    public func move(_ task: Task, to quadrant: Quadrant) async throws {
        var t = task
        t.urgent = quadrant.isUrgent; t.important = quadrant.isImportant
        t.updatedAt = clock()
        try await repository.upsert(t)
    }

    public func delete(_ task: Task) async throws { try await repository.delete(id: task.id) }

    /// Set `snoozedUntil = now + preset`, clamped to the 1-year max (product spec §6.7).
    public func snooze(_ task: Task, by preset: SnoozePreset) async throws {
        var t = task
        let now = clock()
        let interval = min(preset.interval, FieldLimits.maxSnoozeInterval)
        t.snoozedUntil = now.addingTimeInterval(interval)
        t.updatedAt = now
        try await repository.upsert(t)
    }

    /// Start a time-tracking entry; rejects a second concurrent timer (product spec §6.9).
    public func startTimer(_ task: Task) async throws {
        var t = task
        let now = clock()
        t.timeEntries = try TimeTracking.start(t.timeEntries, now: now,
                                               newID: newID(size: IDGenerator.Size.timeEntry))
        t.updatedAt = now
        try await repository.upsert(t)
    }

    /// Stop the running entry and recalculate `timeSpent` (product spec §6.9).
    public func stopTimer(_ task: Task, notes: String? = nil) async throws {
        var t = task
        let now = clock()
        t.timeEntries = try TimeTracking.stop(t.timeEntries, now: now, notes: notes)
        t.timeSpent = TimeTracking.timeSpentMinutes(t.timeEntries)
        t.updatedAt = now
        try await repository.upsert(t)
    }

    private func newID(size: Int) -> String {
        size == IDGenerator.Size.task ? newID() : IDGenerator.generate(size: size)
    }

    // MARK: Subtasks (product spec §6.6)

    public func addSubtask(to task: Task, title: String) async throws {
        var t = task
        t.subtasks.append(Subtask(id: newID(), title: title, completed: false))
        try await persist(t)
    }

    public func toggleSubtask(in task: Task, subtaskID: String) async throws {
        var t = task
        guard let index = t.subtasks.firstIndex(where: { $0.id == subtaskID }) else { return }
        t.subtasks[index].completed.toggle()
        try await persist(t)
    }

    public func deleteSubtask(in task: Task, subtaskID: String) async throws {
        var t = task
        t.subtasks.removeAll { $0.id == subtaskID }
        try await persist(t)
    }

    public func moveSubtask(in task: Task, fromOffsets: IndexSet, toOffset: Int) async throws {
        var t = task
        // `Array.move(fromOffsets:toOffset:)` is SwiftUI-only; implement it with
        // Foundation primitives so GSDStore stays SwiftUI-free.
        // Remove in reverse-index order to preserve stable indices during removal.
        let moved = fromOffsets.sorted(by: >).map { idx -> Subtask in
            let item = t.subtasks[idx]; t.subtasks.remove(at: idx); return item
        }.reversed()
        // Adjust destination: only source offsets strictly below toOffset have been
        // removed, shifting remaining elements left by exactly that count.
        let shift = fromOffsets.filter { $0 < toOffset }.count
        t.subtasks.insert(contentsOf: moved, at: toOffset - shift)
        try await persist(t)
    }

    // MARK: Dependencies (product spec §6.8)

    /// Add a dependency edge after validating it against the live graph (no
    /// self-reference, the id must exist, no cycle). Throws `DependencyError` on rejection.
    public func addDependency(_ dependencyID: String, to task: Task) async throws {
        let graph = DependencyGraph(tasks: tasks)
        try graph.validateAdd(dependency: dependencyID, to: task.id)
        var t = task
        guard !t.dependencies.contains(dependencyID) else { return }
        t.dependencies.append(dependencyID)
        try await persist(t)
    }

    public func removeDependency(_ dependencyID: String, from task: Task) async throws {
        var t = task
        t.dependencies.removeAll { $0 == dependencyID }
        try await persist(t)
    }

    /// Shared write path: stamp `updatedAt` and upsert. (Subtask/dependency edits do
    /// not re-validate field limits here — the editor's Save path does, via `save`.)
    private func persist(_ task: Task) async throws {
        var t = task
        t.updatedAt = clock()
        try await repository.upsert(t)
    }

    // MARK: Reads

    public func tasks(in quadrant: Quadrant, showCompleted: Bool) -> [Task] {
        tasks
            .filter { $0.quadrant == quadrant && (showCompleted || !$0.completed) }
            .sorted { a, b in a.completed == b.completed ? a.updatedAt > b.updatedAt : !a.completed }
    }
}
