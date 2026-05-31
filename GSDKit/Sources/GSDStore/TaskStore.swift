import Foundation
import Observation
import GSDModel

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

    // MARK: Reads

    public func tasks(in quadrant: Quadrant, showCompleted: Bool) -> [Task] {
        tasks
            .filter { $0.quadrant == quadrant && (showCompleted || !$0.completed) }
            .sorted { a, b in a.completed == b.completed ? a.updatedAt > b.updatedAt : !a.completed }
    }
}
