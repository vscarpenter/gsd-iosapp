import Foundation
import GSDModel

/// Decides what the iPhone does with one watch command (spec 6.3). Pure: the App-layer applier
/// only calls `TaskStore` with the action this returns. `toggleComplete` flips state, so every
/// decision checks the task's current state first; without that, a command delivered twice
/// would complete a task and then reopen it.
public enum WatchCommandPlan {
    public enum Action: Sendable, Equatable {
        case toggleComplete
        /// `TaskStore.move`; importance never changes.
        case move(to: Quadrant)
        /// `TaskStore.snooze(by: .oneHour)`.
        case snoozeOneHour
        /// The applier parses `text` with `CaptureParser`, so both devices read it the same way,
        /// then adds it with `quadrant` as the override.
        case capture(text: String, quadrant: Quadrant)
        /// This date and rank, as an ordinary edit (`TaskStore.save`). The date is the one the
        /// rank was chosen for, so a command applied across midnight can't mix the two days.
        case pickForToday(date: String, rank: Int)
        /// Clear both pick fields.
        case clearPick
    }

    public enum SkipReason: Sendable, Equatable {
        case duplicate, missingTask, saved, alreadyCompleted, notCompleted, alreadyUrgent, emptyText
        /// Three picks are already in (`TopThree.nextRank` is nil).
        case noFreeRank
        case alreadyPicked, notAPick
    }

    public enum Decision: Sendable, Equatable {
        case apply(Action)
        case skip(SkipReason)
    }

    /// `today` is the iPhone's local date as `TopThree` writes it, and `nextRank` is
    /// `TopThree.nextRank` for the current tasks. Both are required: a caller that forgot them would
    /// get a silent skip for `addToToday`, which the applier records as done.
    public static func decide(_ command: WatchCommand, task: Task?, alreadyApplied: Bool,
                              today: String, nextRank: Int?) -> Decision {
        if alreadyApplied { return .skip(.duplicate) }

        // A task Saved since the watch's snapshot is out of reach: the builder never sends Saved
        // rows, and `TaskStore.toggleComplete` refuses one. Skipping lets the watch drop the change.
        if let task, task.isSaved, command.taskID != nil { return .skip(.saved) }

        switch command.kind {
        case .capture(let text, let quadrant):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? .skip(.emptyText) : .apply(.capture(text: trimmed, quadrant: quadrant))
        case .addToToday:
            guard let task else { return .skip(.missingTask) }
            if task.completed { return .skip(.alreadyCompleted) }
            if task.focusDate == today, task.focusRank != nil { return .skip(.alreadyPicked) }
            guard let nextRank else { return .skip(.noFreeRank) }
            return .apply(.pickForToday(date: today, rank: nextRank))
        case .removeFromToday:
            guard let task else { return .skip(.missingTask) }
            return task.focusDate == nil && task.focusRank == nil ? .skip(.notAPick) : .apply(.clearPick)
        case .complete:
            guard let task else { return .skip(.missingTask) }
            return task.completed ? .skip(.alreadyCompleted) : .apply(.toggleComplete)
        case .reopen:
            guard let task else { return .skip(.missingTask) }
            return task.completed ? .apply(.toggleComplete) : .skip(.notCompleted)
        case .markUrgent:
            guard let task else { return .skip(.missingTask) }
            if task.completed { return .skip(.alreadyCompleted) }
            if task.urgent { return .skip(.alreadyUrgent) }
            return .apply(.move(to: task.important ? .urgentImportant : .urgentNotImportant))
        case .snooze:
            guard let task else { return .skip(.missingTask) }
            return task.completed ? .skip(.alreadyCompleted) : .apply(.snoozeOneHour)
        }
    }

    /// Parses capture text like the iPhone capture bar, then clamps the title to the field limit.
    /// Dictation on the watch can run past 80 characters, and `TaskStore.add` refuses those.
    public static func parseCapture(_ text: String) -> ParsedCapture {
        var parsed = CaptureParser.parse(text)
        parsed.title = String(parsed.title.prefix(FieldLimits.titleRange.upperBound))
        return parsed
    }

    /// Whether the watch should hold the draft: the title runs past the field limit the phone
    /// would clamp it to.
    public static func captureOverLimit(_ text: String) -> Bool {
        CaptureParser.parse(text).title.count > FieldLimits.titleRange.upperBound
    }
}
