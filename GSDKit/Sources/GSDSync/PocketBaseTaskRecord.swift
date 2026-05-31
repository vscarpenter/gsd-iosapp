import Foundation
import GSDModel

/// The flattened wire form of a `TimeEntry` (§7.1): the wire drops `endedAt`/`notes` and carries
/// a whole-minute `minutes` duration. `startedAt` is a raw ISO-8601 string (parsed via `WireDate`).
struct WireTimeEntry: Codable, Equatable {
    var id: String
    var startedAt: String
    var minutes: Int
}

/// Faithful §7.1 PocketBase `tasks` record (snake_case wire model). Date fields are raw `String`s —
/// leniency lives in `WireDate`, not here. System `created`/`updated` are omitted (§7.1 forbids
/// using them for sort/filter). Decoding is DEFENSIVE: only `task_id` (the join key) is required;
/// every other field defaults so empty-string, JSON-null, and key-absent all decode without
/// throwing (mirrors the `Task.init(from:)` lenient-decode precedent). `Subtask` is reused from
/// `GSDModel` because it already matches the §7.1 `{id,title,completed}` shape.
struct PocketBaseTaskRecord: Codable, Equatable {
    var id: String                 // PocketBase record id (system) — distinct from task_id
    var taskId: String             // the app's Task.id — the join key
    var owner: String
    var title: String
    var description: String
    var urgent: Bool
    var important: Bool
    var quadrant: String
    var dueDate: String
    var completed: Bool
    var completedAt: String
    var recurrence: String
    var tags: [String]
    var subtasks: [Subtask]
    var dependencies: [String]
    var notificationEnabled: Bool
    var notificationSent: Bool
    var notifyBefore: Int?
    var lastNotificationAt: String
    var estimatedMinutes: Int?
    var timeSpent: Int
    var timeEntries: [WireTimeEntry]
    var snoozedUntil: String
    var clientUpdatedAt: String
    var clientCreatedAt: String
    var deviceId: String

    enum CodingKeys: String, CodingKey {
        case id
        case taskId = "task_id"
        case owner, title, description, urgent, important, quadrant
        case dueDate = "due_date"
        case completed
        case completedAt = "completed_at"
        case recurrence, tags, subtasks, dependencies
        case notificationEnabled = "notification_enabled"
        case notificationSent = "notification_sent"
        case notifyBefore = "notify_before"
        case lastNotificationAt = "last_notification_at"
        case estimatedMinutes = "estimated_minutes"
        case timeSpent = "time_spent"
        case timeEntries = "time_entries"
        case snoozedUntil = "snoozed_until"
        case clientUpdatedAt = "client_updated_at"
        case clientCreatedAt = "client_created_at"
        case deviceId = "device_id"
    }

    /// Defensive decode (§7.1): `task_id` required; everything else defaults. `encode(to:)` stays
    /// synthesized (uses the snake_case `CodingKeys`; nil optionals are omitted via `encodeIfPresent`).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        taskId = try c.decode(String.self, forKey: .taskId)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        owner = try c.decodeIfPresent(String.self, forKey: .owner) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        urgent = try c.decodeIfPresent(Bool.self, forKey: .urgent) ?? false
        important = try c.decodeIfPresent(Bool.self, forKey: .important) ?? false
        quadrant = try c.decodeIfPresent(String.self, forKey: .quadrant) ?? ""
        dueDate = try c.decodeIfPresent(String.self, forKey: .dueDate) ?? ""
        completed = try c.decodeIfPresent(Bool.self, forKey: .completed) ?? false
        completedAt = try c.decodeIfPresent(String.self, forKey: .completedAt) ?? ""
        recurrence = try c.decodeIfPresent(String.self, forKey: .recurrence) ?? "none"
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        subtasks = try c.decodeIfPresent([Subtask].self, forKey: .subtasks) ?? []
        dependencies = try c.decodeIfPresent([String].self, forKey: .dependencies) ?? []
        notificationEnabled = try c.decodeIfPresent(Bool.self, forKey: .notificationEnabled) ?? true
        notificationSent = try c.decodeIfPresent(Bool.self, forKey: .notificationSent) ?? false
        notifyBefore = try c.decodeIfPresent(Int.self, forKey: .notifyBefore)
        lastNotificationAt = try c.decodeIfPresent(String.self, forKey: .lastNotificationAt) ?? ""
        estimatedMinutes = try c.decodeIfPresent(Int.self, forKey: .estimatedMinutes)
        timeSpent = try c.decodeIfPresent(Int.self, forKey: .timeSpent) ?? 0
        timeEntries = try c.decodeIfPresent([WireTimeEntry].self, forKey: .timeEntries) ?? []
        snoozedUntil = try c.decodeIfPresent(String.self, forKey: .snoozedUntil) ?? ""
        clientUpdatedAt = try c.decodeIfPresent(String.self, forKey: .clientUpdatedAt) ?? ""
        clientCreatedAt = try c.decodeIfPresent(String.self, forKey: .clientCreatedAt) ?? ""
        deviceId = try c.decodeIfPresent(String.self, forKey: .deviceId) ?? ""
    }

    /// Memberwise init (the synthesized one is suppressed by the custom `init(from:)`); used by
    /// `TaskWireMapper.toWire`.
    init(id: String, taskId: String, owner: String, title: String, description: String,
         urgent: Bool, important: Bool, quadrant: String, dueDate: String, completed: Bool,
         completedAt: String, recurrence: String, tags: [String], subtasks: [Subtask],
         dependencies: [String], notificationEnabled: Bool, notificationSent: Bool,
         notifyBefore: Int?, lastNotificationAt: String, estimatedMinutes: Int?, timeSpent: Int,
         timeEntries: [WireTimeEntry], snoozedUntil: String, clientUpdatedAt: String,
         clientCreatedAt: String, deviceId: String) {
        self.id = id; self.taskId = taskId; self.owner = owner; self.title = title
        self.description = description; self.urgent = urgent; self.important = important
        self.quadrant = quadrant; self.dueDate = dueDate; self.completed = completed
        self.completedAt = completedAt; self.recurrence = recurrence; self.tags = tags
        self.subtasks = subtasks; self.dependencies = dependencies
        self.notificationEnabled = notificationEnabled; self.notificationSent = notificationSent
        self.notifyBefore = notifyBefore; self.lastNotificationAt = lastNotificationAt
        self.estimatedMinutes = estimatedMinutes; self.timeSpent = timeSpent
        self.timeEntries = timeEntries; self.snoozedUntil = snoozedUntil
        self.clientUpdatedAt = clientUpdatedAt; self.clientCreatedAt = clientCreatedAt
        self.deviceId = deviceId
    }
}

/// Decodes one element of an array independently, swallowing per-element errors so a single
/// malformed record yields `nil` rather than aborting the whole batch (§7.4 skip-malformed).
private struct Failable<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

extension PocketBaseTaskRecord {
    /// Decode a PocketBase list payload, SKIPPING malformed records (§7.4) rather than failing the
    /// whole batch. Each element is decoded independently via `Failable`.
    static func decodeList(_ data: Data, decoder: JSONDecoder = JSONDecoder()) throws -> [PocketBaseTaskRecord] {
        try decoder.decode([Failable<PocketBaseTaskRecord>].self, from: data).compactMap(\.value)
    }
}
