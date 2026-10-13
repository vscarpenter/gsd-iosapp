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

    // MARK: The editor's tidy-ups are not edits

    @Test func untouchedAppliesOnlyTheEditorsTidyUps() {
        var task = opened
        task.title = "  padded  "; task.estimatedMinutes = 0
        task.notificationEnabled = true; task.notifyBefore = 30   // on, but no due date
        let untouched = EditorMerge.untouched(task)
        #expect(untouched.title == "padded")
        #expect(untouched.estimatedMinutes == nil)
        #expect(untouched.notificationEnabled == false)            // the editor shows no reminder without a date
        #expect(untouched.notifyBefore == nil)
    }

    @Test func aTitleOnlyEditKeepsAReminderSetElsewhere() {
        // Quick-add leaves reminders on with no due date; the editor shows that as off. Meanwhile
        // another device gave the task a due date and a 30-minute reminder.
        var original = opened; original.notificationEnabled = true
        var current = original
        current.dueDate = t0.addingTimeInterval(86_400); current.notifyBefore = 30
        var edited = EditorMerge.untouched(original); edited.title = "retitled"
        let merged = EditorMerge.merge(current: current, original: EditorMerge.untouched(original), edited: edited)
        #expect(merged.title == "retitled")
        #expect(merged.dueDate == t0.addingTimeInterval(86_400))
        #expect(merged.notificationEnabled)
        #expect(merged.notifyBefore == 30)
    }

    @Test func aTitleTheEditorOnlyTrimmedKeepsARenameFromElsewhere() {
        var original = opened; original.title = "  opened  "
        var current = original; current.title = "renamed elsewhere"
        let edited = EditorMerge.untouched(original)
        let merged = EditorMerge.merge(current: current, original: EditorMerge.untouched(original), edited: edited)
        #expect(merged.title == "renamed elsewhere")
    }

    @Test func aDueDateSetInTheEditorSavesTheReminderAsTheEditorShowedIt() {
        // The due date and its reminder move together, so the save matches what the sheet showed:
        // a new date with the reminder still off.
        var original = opened; original.notificationEnabled = true
        var edited = EditorMerge.untouched(original); edited.dueDate = t0
        let merged = EditorMerge.merge(current: original, original: EditorMerge.untouched(original), edited: edited)
        #expect(merged.dueDate == t0)
        #expect(merged.notificationEnabled == false)
    }
}
