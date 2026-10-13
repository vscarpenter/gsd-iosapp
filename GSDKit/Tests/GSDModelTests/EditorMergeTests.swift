import Testing
import Foundation
@testable import GSDModel

/// Parity C10 (backlog B-03): what the editor's Save writes when the stored row moved while the
/// sheet was open. The same cases as Android's `EditorRulesTest` merge section.
struct EditorMergeTests {
    private let t0 = Date(timeIntervalSince1970: 1_780_000_000)
    private var opened: Task {
        Task(id: "a", title: "opened", urgent: true, important: true, createdAt: t0, updatedAt: t0)
    }

    @Test func aCompletionMadeWhileTheEditorWasOpenSurvivesTheSave() {
        var current = opened
        current.completed = true; current.completedAt = t0.addingTimeInterval(60)
        var edited = opened; edited.title = "retitled"
        let merged = EditorMerge.merge(current: current, original: opened, edited: edited)
        #expect(merged.title == "retitled")
        #expect(merged.completed)
        #expect(merged.completedAt == t0.addingTimeInterval(60))
    }

    @Test func aFieldTheUserChangedWinsOverANewerStoredValue() {
        var current = opened
        current.title = "pulled from another device"; current.description = "pulled notes"
        var edited = opened; edited.title = "typed here"
        let merged = EditorMerge.merge(current: current, original: opened, edited: edited)
        #expect(merged.title == "typed here")
        #expect(merged.description == "pulled notes")   // untouched here, so the newer stored value stays
    }

    @Test func timeTrackedElsewhereSurvivesTheSave() {
        var current = opened
        current.timeEntries = [TimeEntry(id: "e1", startedAt: t0, endedAt: t0.addingTimeInterval(900), notes: nil)]
        current.timeSpent = 15
        var edited = opened; edited.estimatedMinutes = 30
        let merged = EditorMerge.merge(current: current, original: opened, edited: edited)
        #expect(merged.timeEntries.map(\.id) == ["e1"])
        #expect(merged.timeSpent == 15)
        #expect(merged.estimatedMinutes == 30)
    }

    @Test func aSnoozeSetElsewhereSurvivesASaveThatNeverTouchedTheSnooze() {
        var current = opened; current.snoozedUntil = t0.addingTimeInterval(3_600)
        var edited = opened; edited.title = "retitled"
        let merged = EditorMerge.merge(current: current, original: opened, edited: edited)
        #expect(merged.snoozedUntil == t0.addingTimeInterval(3_600))
    }

    @Test func aSnoozeTheUserClearedInTheEditorStaysCleared() {
        var original = opened; original.snoozedUntil = t0.addingTimeInterval(3_600)
        var edited = original; edited.snoozedUntil = nil
        let merged = EditorMerge.merge(current: original, original: original, edited: edited)
        #expect(merged.snoozedUntil == nil)
    }

    @Test func everyEditorFieldTheUserChangedIsWritten() {
        var edited = opened
        edited.description = "d"; edited.urgent = false; edited.important = false
        edited.tags = ["home"]; edited.dueDate = t0; edited.recurrence = .weekly
        edited.subtasks = [Subtask(id: "s1", title: "step", completed: false)]
        edited.dependencies = ["b"]; edited.notificationEnabled = false; edited.notifyBefore = 30
        edited.estimatedMinutes = 45; edited.snoozedUntil = t0
        let merged = EditorMerge.merge(current: opened, original: opened, edited: edited)
        #expect(merged == edited)
    }
}
