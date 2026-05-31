import Foundation

public enum DependencyError: Error, Equatable {
    case selfReference
    case missingTask
    case cycle
}

/// The blocking graph over a task set (product spec §6.8). Edges point from a task
/// to its prerequisites (`task.dependencies`). Pure value type — built from a
/// snapshot, queried, discarded. BFS cycle detection is PROBE-VERIFIED.
public struct DependencyGraph {
    private let byID: [String: Task]
    /// Stable iteration order for deterministic query results.
    private let order: [String]

    public init(tasks: [Task]) {
        var map: [String: Task] = [:]
        var ids: [String] = []
        for task in tasks where map[task.id] == nil {
            map[task.id] = task
            ids.append(task.id)
        }
        self.byID = map
        self.order = ids
    }

    // MARK: Cycle prevention

    /// True if adding `dependency` as a prerequisite of `taskID` would create a cycle.
    /// Self-reference always counts. BFS walks FROM `dependency` over existing edges;
    /// if `taskID` is reachable, the new edge closes a loop.
    public func wouldCreateCycle(adding dependency: String, to taskID: String) -> Bool {
        if dependency == taskID { return true }
        var queue = [dependency]
        var visited: Set<String> = []
        while !queue.isEmpty {
            let current = queue.removeFirst()
            if current == taskID { return true }
            if !visited.insert(current).inserted { continue }
            if let task = byID[current] { queue.append(contentsOf: task.dependencies) }
        }
        return false
    }

    /// Validate an edge before it is added (product spec §6.8): no self-reference,
    /// the dependency must exist, and it must not close a cycle.
    public func validateAdd(dependency: String, to taskID: String) throws {
        guard dependency != taskID else { throw DependencyError.selfReference }
        guard byID[dependency] != nil else { throw DependencyError.missingTask }
        guard !wouldCreateCycle(adding: dependency, to: taskID) else { throw DependencyError.cycle }
    }

    // MARK: Queries

    /// A task's direct prerequisites (its `dependencies`), resolved to tasks.
    public func blockingTasks(of taskID: String) -> [Task] {
        (byID[taskID]?.dependencies ?? []).compactMap { byID[$0] }
    }

    /// Prerequisites that are not yet complete.
    public func uncompletedBlockers(of taskID: String) -> [Task] {
        blockingTasks(of: taskID).filter { !$0.completed }
    }

    /// True if any prerequisite is incomplete.
    public func isBlocked(_ taskID: String) -> Bool {
        !uncompletedBlockers(of: taskID).isEmpty
    }

    /// Tasks that list `taskID` among their dependencies (i.e. this task blocks them).
    public func blockedTasks(of taskID: String) -> [Task] {
        order.compactMap { byID[$0] }.filter { $0.dependencies.contains(taskID) }
    }

    /// Incomplete tasks with no uncompleted blockers — the "Ready to Work" set.
    public func readyTasks() -> [Task] {
        order.compactMap { byID[$0] }.filter { !$0.completed && !isBlocked($0.id) }
    }
}
