import Foundation
import Testing
@testable import GSDModel

struct SavedActiveSurfaceTests {
    private let now = Date(timeIntervalSince1970: 1_793_016_000)
    private let calendar = Calendar(identifier: .gregorian)

    private func saved() -> Task {
        Task(id: "reference", title: "Read later", urgent: true, important: true,
             createdAt: now, updatedAt: now, dueDate: now, savedAt: now)
    }

    @Test func smartViewsExcludeSavedButRetainItsDependencyEdges() {
        let blocker = saved()
        let dependent = Task(id: "work", title: "Blocked work", urgent: true, important: true,
                             createdAt: now, updatedAt: now, dependencies: [blocker.id])
        let all = [blocker, dependent]
        #expect(TaskFilter.apply(FilterCriteria(), to: all, now: now, calendar: calendar).map(\.id) == [dependent.id])
        #expect(TaskFilter.apply(FilterCriteria(readyToWork: true), to: all, now: now, calendar: calendar).isEmpty)
        #expect(DependencyGraph(tasks: all).uncompletedBlockers(of: dependent.id).map(\.id) == [blocker.id])
    }

    @Test func savedDoesNotContributeToAnalyticsOrReminders() {
        let task = saved()
        let summary = AnalyticsEngine.compute(tasks: [task], now: now, calendar: calendar, trendDays: 7)
        #expect(summary.totalCount == 0)
        #expect(summary.activeCount == 0)
        #expect(ReminderMath.badgeCount(tasks: [task], now: now, calendar: calendar) == 0)
        #expect(!ReminderMath.shouldSchedule(task, inputs: .init(masterEnabled: true, defaultReminder: 0)))
    }

    @Test func savedRecordsAreNotAutomaticallyArchived() {
        var task = saved()
        task.completed = true
        task.completedAt = now.addingTimeInterval(-100 * 86400)
        #expect(AutoArchive.tasksToArchive([task], afterDays: 30, now: now, calendar: calendar).isEmpty)
        #expect(TaskFilter.apply(FilterCriteria(), to: [task], now: now, calendar: calendar,
                                 includingSaved: true) == [task])
    }
}
