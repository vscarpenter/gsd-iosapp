import Testing
import Foundation
@testable import GSDModel

/// B-18: the editor asks "Discard changes?" only when the draft differs from what it opened with.
struct EditorDraftTests {
    private func base() -> EditorDraft {
        EditorDraft(title: "Pay rent", description: "", quadrant: .notUrgentImportant, tags: ["home"],
                    dueDate: nil, recurrence: .none, snoozedUntil: nil, notificationEnabled: false,
                    notifyBefore: nil, estimateText: "", subtasks: [], dependencies: [],
                    tagDraft: "", subtaskDraft: "")
    }

    @Test func anUntouchedDraftIsNotDirty() {
        #expect(base().isDirty(since: base()) == false)
    }

    @Test(arguments: [
        ("title", { @Sendable (d: inout EditorDraft) in d.title = "Pay rent today" }),
        ("description", { $0.description = "note" }),
        ("quadrant", { $0.quadrant = .urgentImportant }),
        ("tags", { $0.tags.append("bills") }),
        ("dueDate", { $0.dueDate = Date(timeIntervalSince1970: 1000) }),
        ("recurrence", { $0.recurrence = .weekly }),
        ("snoozedUntil", { $0.snoozedUntil = Date(timeIntervalSince1970: 1000) }),
        ("notificationEnabled", { $0.notificationEnabled = true }),
        ("notifyBefore", { $0.notifyBefore = 30 }),
        ("estimate", { $0.estimateText = "45" }),
        ("subtasks", { $0.subtasks = [Subtask(id: "s1", title: "Call landlord")] }),
        ("dependencies", { $0.dependencies = ["other"] }),
        ("typed tag not yet added", { $0.tagDraft = "bil" }),
        ("typed subtask not yet added", { $0.subtaskDraft = "Call" }),
    ] as [(String, @Sendable (inout EditorDraft) -> Void)])
    func changingAnyFieldMakesItDirty(field: String, change: @Sendable (inout EditorDraft) -> Void) {
        var edited = base()
        change(&edited)
        #expect(edited.isDirty(since: base()), "\(field) should count as a change")
    }

    @Test func changingAFieldBackToItsOriginalIsClean() {
        var edited = base()
        edited.title = "Something else"
        edited.title = "Pay rent"
        #expect(edited.isDirty(since: base()) == false)
    }
}
