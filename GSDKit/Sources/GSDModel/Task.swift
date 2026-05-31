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

    /// Stored properties only. `quadrant` is computed (never persisted/encoded) and is
    /// deliberately absent so synthesized `encode(to:)` skips it.
    private enum CodingKeys: String, CodingKey {
        case id, title, description, urgent, important, completed, completedAt
        case createdAt, updatedAt, dueDate, recurrence, tags, subtasks, dependencies
        case parentTaskId, notifyBefore, notificationEnabled, notificationSent
        case lastNotificationAt, snoozedUntil, estimatedMinutes, timeSpent, timeEntries
    }

    /// Lenient decode (import tolerance — design-spec §3): require only the fields that
    /// have no member-init default; default every other field exactly as the member init
    /// does. Unknown keys are ignored. `encode(to:)` stays synthesized. A task missing a
    /// required field or carrying a wrong-typed value throws (the importer skips+counts it).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        urgent = try c.decode(Bool.self, forKey: .urgent)
        important = try c.decode(Bool.self, forKey: .important)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        completed = try c.decodeIfPresent(Bool.self, forKey: .completed) ?? false
        completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        dueDate = try c.decodeIfPresent(Date.self, forKey: .dueDate)
        recurrence = try c.decodeIfPresent(RecurrenceType.self, forKey: .recurrence) ?? .none
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        subtasks = try c.decodeIfPresent([Subtask].self, forKey: .subtasks) ?? []
        dependencies = try c.decodeIfPresent([String].self, forKey: .dependencies) ?? []
        parentTaskId = try c.decodeIfPresent(String.self, forKey: .parentTaskId)
        notifyBefore = try c.decodeIfPresent(Int.self, forKey: .notifyBefore)
        notificationEnabled = try c.decodeIfPresent(Bool.self, forKey: .notificationEnabled) ?? true
        notificationSent = try c.decodeIfPresent(Bool.self, forKey: .notificationSent) ?? false
        lastNotificationAt = try c.decodeIfPresent(Date.self, forKey: .lastNotificationAt)
        snoozedUntil = try c.decodeIfPresent(Date.self, forKey: .snoozedUntil)
        estimatedMinutes = try c.decodeIfPresent(Int.self, forKey: .estimatedMinutes)
        timeSpent = try c.decodeIfPresent(Int.self, forKey: .timeSpent)
        timeEntries = try c.decodeIfPresent([TimeEntry].self, forKey: .timeEntries) ?? []
    }
}
