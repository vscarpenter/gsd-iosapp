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
    public private(set) var customViews: [SmartView] = []
    public private(set) var archivedTasks: [Task] = []

    private let repository: any TaskRepository
    private let smartViewRepository: any SmartViewRepository
    private let archiveRepository: any ArchiveRepository
    private let defaults: UserDefaults
    private let clock: @Sendable () -> Date
    private let newID: @Sendable () -> String
    private let calendar: Calendar
    // Stored var so @Observable tracks mutations; UserDefaults is the persistence backing.
    private var pinnedIDs: [String] = []
    // nonisolated(unsafe) so deinit can cancel without a MainActor hop.
    nonisolated(unsafe) private var observerTask: _Concurrency.Task<Void, Never>?
    nonisolated(unsafe) private var smartViewObserverTask: _Concurrency.Task<Void, Never>?
    nonisolated(unsafe) private var archiveObserverTask: _Concurrency.Task<Void, Never>?

    public init(
        repository: any TaskRepository,
        smartViewRepository: any SmartViewRepository,
        archiveRepository: any ArchiveRepository,
        defaults: UserDefaults = AppGroupDefaults.shared,
        clock: @escaping @Sendable () -> Date = { Date() },
        newID: @escaping @Sendable () -> String = { IDGenerator.generate(size: IDGenerator.Size.smartView) },
        calendar: Calendar = .current
    ) {
        self.repository = repository
        self.smartViewRepository = smartViewRepository
        self.archiveRepository = archiveRepository
        self.defaults = defaults
        self.clock = clock
        self.newID = newID
        self.calendar = calendar
        self.pinnedIDs = defaults.stringArray(forKey: AppGroupDefaults.Key.pinnedSmartViewIds) ?? []
    }

    /// Begin observing all repositories. Idempotent; call once from the app root.
    public func start() {
        startTaskObserver()
        startSmartViewObserver()
        startArchiveObserver()
    }

    private func startTaskObserver() {
        guard observerTask == nil else { return }
        let stream = repository.observeAll()
        observerTask = _Concurrency.Task { [weak self] in
            do { for try await snapshot in stream { self?.tasks = snapshot } } catch {}
        }
    }
    private func startSmartViewObserver() {
        guard smartViewObserverTask == nil else { return }
        let stream = smartViewRepository.observeAll()
        smartViewObserverTask = _Concurrency.Task { [weak self] in
            do { for try await snapshot in stream { self?.customViews = snapshot } } catch {}
        }
    }
    private func startArchiveObserver() {
        guard archiveObserverTask == nil else { return }
        let stream = archiveRepository.observeAll()
        archiveObserverTask = _Concurrency.Task { [weak self] in
            do { for try await snapshot in stream { self?.archivedTasks = snapshot } } catch {}
        }
    }

    deinit {
        observerTask?.cancel()
        smartViewObserverTask?.cancel()
        archiveObserverTask?.cancel()
    }

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
        let now = clock()
        // Decide the completion transition from the PERSISTED row, not the
        // (async-lagging) snapshot the caller holds — otherwise a double-fired
        // complete spawns duplicate recurrence instances (mirrors addDependency's
        // ground-truth read).
        let persisted = try await repository.fetch(id: task.id)
        let willComplete = !(persisted?.completed ?? task.completed)

        var t = task
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
        guard t.subtasks.contains(where: { $0.id == subtaskID }) else { return }
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
        let allTasks = try await repository.fetchAll()
        let graph = DependencyGraph(tasks: allTasks)
        try graph.validateAdd(dependency: dependencyID, to: task.id)
        var t = task
        guard !t.dependencies.contains(dependencyID) else { return }
        t.dependencies.append(dependencyID)
        try await persist(t)
    }

    public func removeDependency(_ dependencyID: String, from task: Task) async throws {
        var t = task
        guard t.dependencies.contains(dependencyID) else { return }
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

    /// Tasks matching a `FilterCriteria` (product spec §5.9), resolved with the store's
    /// injected clock/calendar. Pure/derived — delegates to `TaskFilter`; never mutates.
    public func tasks(matching criteria: FilterCriteria) -> [Task] {
        TaskFilter.apply(criteria, to: tasks, now: clock(), calendar: calendar)
    }

    /// The dashboard summary over the live task snapshot, resolved with the store's
    /// injected clock/calendar. Pure/derived — delegates to `AnalyticsEngine`; never mutates.
    public func analytics(trendDays: Int) -> AnalyticsSummary {
        AnalyticsEngine.compute(tasks: tasks, now: clock(), calendar: calendar, trendDays: trendDays)
    }

    // MARK: Smart views (custom CRUD + pinning)

    /// Pinned ids first (in pin order), then the 9 built-ins, then custom views — with
    /// pinned ids de-duplicated out of their home section (product spec §6.13).
    public var allViews: [SmartView] {
        let everything = BuiltInSmartViews.all + customViews
        let byID = Dictionary(everything.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let pinned = pinnedSmartViewIds.compactMap { byID[$0] }
        let pinnedSet = Set(pinned.map(\.id))
        let rest = everything.filter { !pinnedSet.contains($0.id) }
        return pinned + rest
    }

    public var pinnedViews: [SmartView] {
        let byID = Dictionary((BuiltInSmartViews.all + customViews).map { ($0.id, $0) },
                              uniquingKeysWith: { a, _ in a })
        return pinnedSmartViewIds.compactMap { byID[$0] }
    }

    public func createView(name: String, icon: String, criteria: FilterCriteria) async throws {
        let now = clock()
        let view = SmartView(id: newID(), name: name, icon: icon, criteria: criteria, isBuiltIn: false)
        try await smartViewRepository.upsert(view, createdAt: now, updatedAt: now)
    }

    /// Update a custom view's name/icon/criteria, stamping `updatedAt` via the clock.
    /// `createdAt` is re-stamped to `now` on edit (the `SmartView` domain model doesn't
    /// carry it, and UI ordering uses `updatedAt`) — see the note below.
    public func updateView(_ view: SmartView) async throws {
        let now = clock()
        try await smartViewRepository.upsert(view, createdAt: now, updatedAt: now)
    }

    public func deleteView(id: String) async throws {
        try await smartViewRepository.delete(id: id)
        unpin(id)   // a deleted view can't stay pinned
    }

    // MARK: Pinning (App-Group UserDefaults; ordered, capped at SmartViewPinning.maxPins)

    // pinnedIDs is the reactive source of truth (@Observable tracks it); defaults is
    // the persistence backing. Both are kept in sync on every mutation.
    public var pinnedSmartViewIds: [String] { pinnedIDs }

    public func pin(_ id: String) {
        let newList = SmartViewPinning.pin(id, in: pinnedIDs)
        pinnedIDs = newList
        defaults.set(newList, forKey: AppGroupDefaults.Key.pinnedSmartViewIds)
    }
    public func unpin(_ id: String) {
        let newList = SmartViewPinning.unpin(id, in: pinnedIDs)
        pinnedIDs = newList
        defaults.set(newList, forKey: AppGroupDefaults.Key.pinnedSmartViewIds)
    }
    public func reorderPins(fromOffsets: IndexSet, toOffset: Int) {
        let newList = SmartViewPinning.reorder(pinnedIDs, fromOffsets: fromOffsets, toOffset: toOffset)
        pinnedIDs = newList
        defaults.set(newList, forKey: AppGroupDefaults.Key.pinnedSmartViewIds)
    }

    // MARK: Archive

    /// Move a task into the archive (removed from active). Goes through the archive
    /// repository's single-transaction move; the observers refresh `tasks`/`archivedTasks`.
    /// NOTE (Phase 5): enqueue a sync op here.
    public func archive(_ task: Task) async throws {
        try await archiveRepository.archive(task)
    }

    /// Restore an archived task to active, stamping `updatedAt` so it sorts fresh.
    /// Two writes: the repository re-inserts the stored row, then we upsert the freshened
    /// `updatedAt` (the active observer coalesces both into one snapshot).
    public func restore(_ task: Task) async throws {
        var t = task
        t.updatedAt = clock()
        try await archiveRepository.restore(id: task.id)
        try await repository.upsert(t)
    }

    public func deletePermanently(_ task: Task) async throws {
        try await archiveRepository.deletePermanently(id: task.id)
    }

    /// Archive every completed task older than the configured threshold — but only when
    /// auto-archive is enabled. Pure selection via `AutoArchive`; gating lives here.
    public func runAutoArchiveSweep() async throws {
        let settings = archiveSettings
        guard settings.autoEnabled else { return }
        let allTasks = try await repository.fetchAll()
        let toArchive = AutoArchive.tasksToArchive(allTasks, afterDays: settings.afterDays,
                                                   now: clock(), calendar: calendar)
        for task in toArchive { try await archiveRepository.archive(task) }
    }

    // MARK: Archive settings (App-Group UserDefaults; design-spec scope call)

    public var archiveSettings: ArchiveSettings {
        get {
            ArchiveSettings(
                autoEnabled: defaults.bool(forKey: AppGroupDefaults.Key.archiveAutoEnabled),
                afterDays: defaults.object(forKey: AppGroupDefaults.Key.archiveAfterDays) as? Int ?? 30
            )
        }
        set {
            defaults.set(newValue.autoEnabled, forKey: AppGroupDefaults.Key.archiveAutoEnabled)
            defaults.set(newValue.afterDays, forKey: AppGroupDefaults.Key.archiveAfterDays)
        }
    }

    // MARK: Bulk operations (multi-select; each op is per-task, validated, stamps updatedAt)

    private func selectedTasks(_ ids: Set<String>) -> [Task] {
        tasks.filter { ids.contains($0.id) }
    }

    public func bulkComplete(ids: Set<String>) async throws {
        for task in selectedTasks(ids) where !task.completed {
            try? await toggleComplete(task)   // stamps completedAt/updatedAt + spawns recurrence
        }
    }
    public func bulkMove(ids: Set<String>, to quadrant: Quadrant) async throws {
        for task in selectedTasks(ids) { try? await move(task, to: quadrant) }
    }
    public func bulkAddTags(ids: Set<String>, tags newTags: [String]) async throws {
        for var task in selectedTasks(ids) {
            let merged = task.tags + newTags.filter { !task.tags.contains($0) }
            task.tags = merged
            try? await save(task)             // save validates (tag count/length) + stamps updatedAt
        }
    }
    public func bulkRemoveTags(ids: Set<String>, tags removeTags: [String]) async throws {
        let toRemove = Set(removeTags)
        for var task in selectedTasks(ids) {
            task.tags.removeAll { toRemove.contains($0) }
            try? await save(task)
        }
    }
    public func bulkSetDue(ids: Set<String>, to dueDate: Date?) async throws {
        for var task in selectedTasks(ids) {
            task.dueDate = dueDate
            try? await save(task)
        }
    }
    public func bulkDelete(ids: Set<String>) async throws {
        for task in selectedTasks(ids) { try? await delete(task) }
    }

    // MARK: Data (export / import / reset)

    public enum ImportMode: Sendable { case replace, merge }

    /// Serialize the live task snapshot to a `TaskExport` JSON payload (design-spec §3).
    public func exportJSON() throws -> Data {
        try TaskExport.encode(TaskExport(tasks: tasks, exportedAt: clock()))
    }

    /// Parse + persist an import. Replace clears all tasks then bulk-inserts (single
    /// transaction); Merge regenerates colliding ids + remaps references, then upserts each
    /// (stamping `updatedAt` via the clock). Limits + lenient decode live in `TaskImporter`.
    /// Returns the parse result so the UI can report skipped-count.
    /// NOTE (Phase 5): enqueue a sync op for each written task here.
    @discardableResult
    public func importTasks(_ data: Data, mode: ImportMode) async throws -> ImportResult {
        switch mode {
        case .replace:
            let result = try TaskImporter.replace(from: data)
            let now = clock()
            let stamped = result.tasks.map { task -> Task in
                var t = task; t.updatedAt = now; return t
            }
            try await repository.replaceAll(stamped)
            return result
        case .merge:
            let existing = Set(try await repository.fetchAll().map(\.id))
            let result = try TaskImporter.merge(from: data, existingIDs: existing, newID: { self.newID() })
            for task in result.tasks {
                var t = task; t.updatedAt = clock()
                try await repository.upsert(t)
            }
            return result
        }
    }

    /// Erase all app data EXCEPT the theme (design-spec §3 reset scope call): clears tasks,
    /// archived tasks, custom smart views, pinning, and archive settings. `appTheme` +
    /// `hasOnboarded` live in the App layer's `@AppStorage` and are intentionally untouched.
    public func eraseAllData() async throws {
        try await repository.replaceAll([])
        for archived in try await archiveRepository.fetchAll() {
            try await archiveRepository.deletePermanently(id: archived.id)
        }
        for view in try await smartViewRepository.fetchAll() {
            try await smartViewRepository.delete(id: view.id)
        }
        pinnedIDs = []
        defaults.removeObject(forKey: AppGroupDefaults.Key.pinnedSmartViewIds)
        defaults.removeObject(forKey: AppGroupDefaults.Key.archiveAutoEnabled)
        defaults.removeObject(forKey: AppGroupDefaults.Key.archiveAfterDays)
    }
}
