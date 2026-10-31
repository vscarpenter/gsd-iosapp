import Foundation

/// Everything the task editor lets the user change, as one comparable value. The editor
/// snapshots it when the sheet opens and compares on close, so it asks "Discard changes?"
/// only when something differs. Text typed into the tag or subtask field but not yet added
/// counts: closing would lose it.
public struct EditorDraft: Equatable, Sendable {
    public var title: String
    public var description: String
    public var quadrant: Quadrant
    public var tags: [String]
    public var dueDate: Date?
    public var recurrence: RecurrenceType
    public var snoozedUntil: Date?
    public var notificationEnabled: Bool
    public var notifyBefore: Int?
    public var estimateText: String
    public var subtasks: [Subtask]
    public var dependencies: [String]
    public var tagDraft: String
    public var subtaskDraft: String

    public init(title: String, description: String, quadrant: Quadrant, tags: [String],
                dueDate: Date?, recurrence: RecurrenceType, snoozedUntil: Date?,
                notificationEnabled: Bool, notifyBefore: Int?, estimateText: String,
                subtasks: [Subtask], dependencies: [String], tagDraft: String, subtaskDraft: String) {
        self.title = title; self.description = description; self.quadrant = quadrant; self.tags = tags
        self.dueDate = dueDate; self.recurrence = recurrence; self.snoozedUntil = snoozedUntil
        self.notificationEnabled = notificationEnabled; self.notifyBefore = notifyBefore
        self.estimateText = estimateText; self.subtasks = subtasks; self.dependencies = dependencies
        self.tagDraft = tagDraft; self.subtaskDraft = subtaskDraft
    }

    public func isDirty(since baseline: EditorDraft) -> Bool { self != baseline }
}
