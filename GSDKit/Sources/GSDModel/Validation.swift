import Foundation

/// Authoritative field limits (product spec §5.1, Appendix B). Named constants,
/// no magic numbers.
public enum FieldLimits {
    public static let titleRange = 1...80
    public static let descriptionMax = 600
    public static let tagLengthRange = 1...30
    public static let maxTags = 20
    public static let subtaskTitleRange = 1...100
    public static let maxSubtasks = 50
    public static let maxDependencies = 50
    /// Enforced at the time-entry note input UI (Phase 2), NOT inside `TaskValidator.validate`.
    public static let timeEntryNoteMax = 200
    public static let maxTimeEntries = 1000
    public static let estimatedMinutesRange = 1...10080   // 1 min – 7 days
    /// Enforced at the snooze action UI (Phase 2), NOT inside `TaskValidator.validate`.
    public static let maxSnoozeInterval: TimeInterval = 365 * 24 * 60 * 60

    /// A stored estimate of 0 means "unset" (product spec §5.1).
    public static func normalizedEstimate(_ value: Int?) -> Int? {
        guard let value, value != 0 else { return nil }
        return value
    }
}

public enum ValidationError: Error, Equatable {
    case titleLength
    case descriptionTooLong
    case tagLength
    case tooManyTags
    case subtaskTitleLength
    case tooManySubtasks
    case tooManyDependencies
    case estimateOutOfRange
    case tooManyTimeEntries
}

public enum TaskValidator {
    public static func validate(_ task: Task) throws {
        guard FieldLimits.titleRange.contains(task.title.count) else { throw ValidationError.titleLength }
        guard task.description.count <= FieldLimits.descriptionMax else { throw ValidationError.descriptionTooLong }
        guard task.tags.count <= FieldLimits.maxTags else { throw ValidationError.tooManyTags }
        guard task.tags.allSatisfy({ FieldLimits.tagLengthRange.contains($0.count) }) else { throw ValidationError.tagLength }
        guard task.subtasks.count <= FieldLimits.maxSubtasks else { throw ValidationError.tooManySubtasks }
        guard task.subtasks.allSatisfy({ FieldLimits.subtaskTitleRange.contains($0.title.count) }) else { throw ValidationError.subtaskTitleLength }
        guard task.dependencies.count <= FieldLimits.maxDependencies else { throw ValidationError.tooManyDependencies }
        guard task.timeEntries.count <= FieldLimits.maxTimeEntries else { throw ValidationError.tooManyTimeEntries }
        if let estimate = task.estimatedMinutes, estimate != 0 {
            guard FieldLimits.estimatedMinutesRange.contains(estimate) else { throw ValidationError.estimateOutOfRange }
        }
    }
}
