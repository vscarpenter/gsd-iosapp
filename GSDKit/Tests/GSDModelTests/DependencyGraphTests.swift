import Testing
import Foundation
@testable import GSDModel

struct DependencyGraphTests {
    private func task(_ id: String, deps: [String] = [], completed: Bool = false) -> Task {
        let now = Date(timeIntervalSince1970: 0)
        return Task(id: id, title: id, urgent: true, important: true,
                    completed: completed, createdAt: now, updatedAt: now, dependencies: deps)
    }

    /// Chain: A ──depends on──▶ B ──depends on──▶ C   (edges point to prerequisites)
    private func chain() -> DependencyGraph {
        DependencyGraph(tasks: [task("A", deps: ["B"]), task("B", deps: ["C"]), task("C")])
    }

    @Test func selfReferenceRejected() {
        #expect(chain().wouldCreateCycle(adding: "A", to: "A"))
    }

    @Test func edgeClosingCycleRejectedViaBfs() {
        // Adding A as a dependency of C closes C→A→B→C.
        #expect(chain().wouldCreateCycle(adding: "A", to: "C"))
    }

    @Test func transitiveButAcyclicEdgeAllowed() {
        // Adding C as a direct dependency of A is redundant but creates no cycle.
        #expect(!chain().wouldCreateCycle(adding: "C", to: "A"))
    }

    @Test func existingEdgeReAddedIsNotACycle() {
        #expect(!chain().wouldCreateCycle(adding: "B", to: "A"))
    }

    @Test func validateAddRejectsMissingId() {
        #expect(throws: DependencyError.missingTask) {
            try chain().validateAdd(dependency: "ZZZ", to: "A")
        }
    }

    @Test func validateAddRejectsSelfReference() {
        #expect(throws: DependencyError.selfReference) {
            try chain().validateAdd(dependency: "A", to: "A")
        }
    }

    @Test func validateAddRejectsCycle() {
        #expect(throws: DependencyError.cycle) {
            try chain().validateAdd(dependency: "A", to: "C")
        }
    }

    @Test func validateAddAcceptsValidEdge() throws {
        try chain().validateAdd(dependency: "C", to: "A") // redundant but legal
    }

    @Test func blockingTasksAreTheDirectDependencies() {
        #expect(chain().blockingTasks(of: "A").map(\.id) == ["B"])
    }

    @Test func uncompletedBlockersExcludeCompletedPrerequisites() {
        let g = DependencyGraph(tasks: [task("A", deps: ["B", "C"]),
                                        task("B", completed: true),
                                        task("C", completed: false)])
        #expect(g.uncompletedBlockers(of: "A").map(\.id) == ["C"])
        #expect(g.isBlocked("A"))
    }

    @Test func notBlockedWhenAllPrerequisitesComplete() {
        let g = DependencyGraph(tasks: [task("A", deps: ["B"]), task("B", completed: true)])
        #expect(!g.isBlocked("A"))
        #expect(g.uncompletedBlockers(of: "A").isEmpty)
    }

    @Test func blockedTasksAreTasksDependingOnThisOne() {
        // C blocks B (B depends on C). So blockedTasks(of: C) includes B.
        #expect(chain().blockedTasks(of: "C").map(\.id) == ["B"])
    }

    @Test func readyTasksExcludeIncompleteBlockersAndCompletedTasks() {
        // Chain A→B→C all incomplete: only C is ready (no uncompleted blockers).
        #expect(chain().readyTasks().map(\.id) == ["C"])
    }

    @Test func readyTasksExcludeAlreadyCompletedTasks() {
        let g = DependencyGraph(tasks: [task("A", completed: true), task("B")])
        #expect(g.readyTasks().map(\.id) == ["B"])
    }
}
