import Foundation

/// The core entity (product spec §5.1). All fields are stored except
/// `quadrant`, which is derived from `urgent`/`important` so it can never drift.
public struct Task: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var title: String
    public var description: String
    public var urgent: Bool
    public var important: Bool
    public var completed: Bool
    public var completedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date
    public var dueDate: Date?
    public var recurrence: RecurrenceType
    public var tags: [String]
    public var subtasks: [Subtask]
    public var dependencies: [String]
    public var parentTaskId: String?
    public var notifyBefore: Int?
    public var notificationEnabled: Bool
    public var notificationSent: Bool          // device-local
    public var lastNotificationAt: Date?       // device-local
    public var snoozedUntil: Date?             // device-local
    public var estimatedMinutes: Int?
    public var timeSpent: Int?                 // calculated from timeEntries
    public var timeEntries: [TimeEntry]

    /// Derived, never persisted into this struct — the store column is written
    /// from this value (product spec §5.8).
    public var quadrant: Quadrant { Quadrant(urgent: urgent, important: important) }

    public init(
        id: String,
        title: String,
        description: String = "",
        urgent: Bool,
        important: Bool,
        completed: Bool = false,
        completedAt: Date? = nil,
        createdAt: Date,
        updatedAt: Date,
        dueDate: Date? = nil,
        recurrence: RecurrenceType = .none,
        tags: [String] = [],
        subtasks: [Subtask] = [],
        dependencies: [String] = [],
        parentTaskId: String? = nil,
        notifyBefore: Int? = nil,
        notificationEnabled: Bool = true,
        notificationSent: Bool = false,
        lastNotificationAt: Date? = nil,
        snoozedUntil: Date? = nil,
        estimatedMinutes: Int? = nil,
        timeSpent: Int? = nil,
        timeEntries: [TimeEntry] = []
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.urgent = urgent
        self.important = important
        self.completed = completed
        self.completedAt = completedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.dueDate = dueDate
        self.recurrence = recurrence
        self.tags = tags
        self.subtasks = subtasks
        self.dependencies = dependencies
        self.parentTaskId = parentTaskId
        self.notifyBefore = notifyBefore
        self.notificationEnabled = notificationEnabled
        self.notificationSent = notificationSent
        self.lastNotificationAt = lastNotificationAt
        self.snoozedUntil = snoozedUntil
        self.estimatedMinutes = estimatedMinutes
        self.timeSpent = timeSpent
        self.timeEntries = timeEntries
    }
}
