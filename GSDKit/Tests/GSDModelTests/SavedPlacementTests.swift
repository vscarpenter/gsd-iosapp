import Foundation
import Testing
@testable import GSDModel

struct SavedPlacementTests {
    private let now = Date(timeIntervalSince1970: 1_793_016_000)

    private func task(completed: Bool = false, timeEntries: [TimeEntry] = []) -> Task {
        Task(id: "reading", title: "Read later", urgent: false, important: true,
             completed: completed, createdAt: now, updatedAt: now, timeEntries: timeEntries)
    }

    @Test func anOpenTaskWithNoRunningTimerCanBeSaved() {
        let stopped = TimeEntry(id: "e1", startedAt: now, endedAt: now.addingTimeInterval(600))
        #expect(SavedPlacement.refusal(for: task(timeEntries: [stopped])) == nil)
        #expect(SavedPlacement.canSave(task()))
    }

    @Test func aCompletedTaskCantBeSaved() {
        #expect(SavedPlacement.refusal(for: task(completed: true)) == .completed)
        #expect(!SavedPlacement.canSave(task(completed: true)))
    }

    @Test func aTaskWithARunningTimerCantBeSaved() {
        let running = TimeEntry(id: "e1", startedAt: now)
        #expect(SavedPlacement.refusal(for: task(timeEntries: [running])) == .timerRunning)
        #expect(!SavedPlacement.canSave(task(timeEntries: [running])))
    }
}
