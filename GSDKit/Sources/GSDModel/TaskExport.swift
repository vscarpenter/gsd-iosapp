import Foundation

/// The export/import envelope (design-spec §3), matching the web client's backup
/// envelope byte-for-byte so a backup taken on either client restores on the other.
///
/// `version` is a semver STRING (`"2.1.0"`). It was an `Int` through iOS 2.2.0, which
/// the web app rejected outright — its schema gated on `z.string()`, so an iOS backup
/// never imported. Decode therefore accepts a string *or* a number; encode always
/// writes the string. See the web repo's ADR 0014 (amended 2026-08-28).
///
/// Every key past `version` is optional in both directions. An ABSENT key means "this
/// backup says nothing about that store", which import must treat differently from an
/// empty array: silence leaves the store alone, `[]` clears it.
public struct TaskExport: Codable, Equatable, Sendable {
    /// What this build writes. Kept in lockstep with the web's `BACKUP_ENVELOPE_VERSION`.
    public static let currentVersion = "2.1.0"

    public var tasks: [Task]
    public var exportedAt: Date
    public var version: String
    public var archivedTasks: [ArchivedTask]?
    public var deletedTasks: [ArchivedTask]?
    public var smartViews: [SmartViewWire]?
    public var notificationSettings: NotificationSettingsWire?
    public var archiveSettings: ArchiveSettingsWire?
    public var appPreferences: AppPreferencesWire?

    public init(tasks: [Task],
                exportedAt: Date,
                version: String = TaskExport.currentVersion,
                archivedTasks: [ArchivedTask]? = nil,
                deletedTasks: [ArchivedTask]? = nil,
                smartViews: [SmartViewWire]? = nil,
                notificationSettings: NotificationSettingsWire? = nil,
                archiveSettings: ArchiveSettingsWire? = nil,
                appPreferences: AppPreferencesWire? = nil) {
        self.tasks = tasks
        self.exportedAt = exportedAt
        self.version = version
        self.archivedTasks = archivedTasks
        self.deletedTasks = deletedTasks
        self.smartViews = smartViews
        self.notificationSettings = notificationSettings
        self.archiveSettings = archiveSettings
        self.appPreferences = appPreferences
    }

    private enum CodingKeys: String, CodingKey {
        case tasks, exportedAt, version, archivedTasks, deletedTasks
        case smartViews, notificationSettings, archiveSettings, appPreferences
    }

    /// Tasks are written through `BackupTask` so each one carries the derived `quadrant`.
    /// This app computes that from `urgent`/`important` and never stores it, but the web
    /// persists it as an indexed column and its import schema REQUIRES it — an export
    /// without it is refused outright. Sync already writes it for the same reason
    /// (`TaskWireMapper`), so the backup now follows the same convention.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(tasks.map(BackupTask.init), forKey: .tasks)
        try c.encode(exportedAt, forKey: .exportedAt)
        try c.encode(version, forKey: .version)
        try c.encodeIfPresent(archivedTasks, forKey: .archivedTasks)
        try c.encodeIfPresent(deletedTasks, forKey: .deletedTasks)
        try c.encodeIfPresent(smartViews, forKey: .smartViews)
        try c.encodeIfPresent(notificationSettings, forKey: .notificationSettings)
        try c.encodeIfPresent(archiveSettings, forKey: .archiveSettings)
        try c.encodeIfPresent(appPreferences, forKey: .appPreferences)
    }

    /// Lenient on `version` only: accept the legacy `Int` as well as the string, so a
    /// backup written by an older build of this app still round-trips. Everything else
    /// decodes normally; unknown keys are ignored by `Codable` default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tasks = try c.decode([Task].self, forKey: .tasks)
        exportedAt = try c.decode(Date.self, forKey: .exportedAt)
        version = TaskExport.decodeVersion(from: c)
        archivedTasks = try c.decodeIfPresent([ArchivedTask].self, forKey: .archivedTasks)
        deletedTasks = try c.decodeIfPresent([ArchivedTask].self, forKey: .deletedTasks)
        smartViews = try c.decodeIfPresent([SmartViewWire].self, forKey: .smartViews)
        notificationSettings = try c.decodeIfPresent(NotificationSettingsWire.self, forKey: .notificationSettings)
        archiveSettings = try c.decodeIfPresent(ArchiveSettingsWire.self, forKey: .archiveSettings)
        appPreferences = try c.decodeIfPresent(AppPreferencesWire.self, forKey: .appPreferences)
    }

    /// `"2.1.0"` → itself; `1` → `"1"`; absent → `"1"` (the shape older builds wrote).
    /// A wrong-typed or missing value falls through rather than throwing: the version has
    /// never gated anything, so refusing a whole backup over it would be the very failure
    /// this leniency exists to prevent.
    private static func decodeVersion(from c: KeyedDecodingContainer<CodingKeys>) -> String {
        if let s = try? c.decode(String.self, forKey: .version) { return s }
        if let n = try? c.decode(Int.self, forKey: .version) { return String(n) }
        return "1"
    }
}

/// A `Task` encoded for a backup: its own keys, plus the derived `quadrant`.
///
/// `Task` deliberately omits `quadrant` from its `CodingKeys` so the stored value can never
/// drift from `urgent`/`important`. That invariant is right for this app and wrong for the
/// wire, where the web expects the column. Decoding ignores any incoming `quadrant` and
/// lets `Task` recompute it — the same rule `TaskWireMapper` applies to sync payloads.
public struct BackupTask: Equatable, Sendable {
    public var task: Task
    public init(_ task: Task) { self.task = task }
}

extension BackupTask: Codable {
    private enum QuadrantKey: String, CodingKey { case quadrant }

    public init(from decoder: Decoder) throws {
        task = try Task(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        try task.encode(to: encoder)
        var c = encoder.container(keyedBy: QuadrantKey.self)
        try c.encode(task.quadrant.rawValue, forKey: .quadrant)
    }
}

/// A task plus its archive/trash timestamp, encoded FLAT — every `Task` key at the top
/// level alongside `archivedAt`/`deletedAt` — because that is the shape the web writes.
/// Trash rows reuse this type: the web's `deletedTasks` entries carry `deletedAt`, so
/// `stampKey` selects which key this value reads and writes.
public struct ArchivedTask: Equatable, Sendable {
    public enum StampKey: String, Sendable, CodingKey { case archivedAt, deletedAt }

    public var task: Task
    public var stampedAt: Date
    public var stampKey: StampKey

    public init(task: Task, stampedAt: Date, stampKey: StampKey = .archivedAt) {
        self.task = task
        self.stampedAt = stampedAt
        self.stampKey = stampKey
    }
}

extension ArchivedTask: Codable {
    /// Reads whichever stamp the payload carries. `archivedAt` wins when both are
    /// present, which cannot happen in a well-formed backup — a row lives in exactly
    /// one of the two stores.
    public init(from decoder: Decoder) throws {
        task = try Task(from: decoder)
        let c = try decoder.container(keyedBy: StampKey.self)
        if let archived = try c.decodeIfPresent(Date.self, forKey: .archivedAt) {
            stampedAt = archived
            stampKey = .archivedAt
        } else {
            stampedAt = try c.decode(Date.self, forKey: .deletedAt)
            stampKey = .deletedAt
        }
    }

    /// Encodes the task's own keys (via `BackupTask`, so `quadrant` comes along) and the
    /// stamp into the SAME keyed container, which is how the flat wire shape is produced.
    public func encode(to encoder: Encoder) throws {
        try BackupTask(task).encode(to: encoder)
        var c = encoder.container(keyedBy: StampKey.self)
        try c.encode(stampedAt, forKey: stampKey)
    }
}

/// Wire shape for a stored (custom) smart view. Field names are the WEB's, which is the
/// authority here — its import schema is strict about them. Built-ins are derived at read
/// time on both clients and are never stored, so they never appear in a backup.
public struct SmartViewWire: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var description: String?
    public var icon: String?
    public var criteria: FilterCriteria
    public var isBuiltIn: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String, name: String, description: String? = nil, icon: String? = nil,
                criteria: FilterCriteria, isBuiltIn: Bool = false,
                createdAt: Date, updatedAt: Date) {
        self.id = id
        self.name = name
        self.description = description
        self.icon = icon
        self.criteria = criteria
        self.isBuiltIn = isBuiltIn
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Wire shape for the notification singleton. Carries `id` and `updatedAt`, which this
/// app has no use for but the web's schema requires.
public struct NotificationSettingsWire: Codable, Equatable, Sendable {
    public var id: String
    public var enabled: Bool
    public var defaultReminder: Int
    public var soundEnabled: Bool
    public var quietHoursStart: String?
    public var quietHoursEnd: String?
    public var permissionAsked: Bool
    public var updatedAt: Date

    public init(_ settings: NotificationSettings, updatedAt: Date) {
        id = "settings"
        enabled = settings.enabled
        defaultReminder = settings.defaultReminder
        soundEnabled = settings.soundEnabled
        quietHoursStart = settings.quietHoursStart
        quietHoursEnd = settings.quietHoursEnd
        permissionAsked = settings.permissionAsked
        self.updatedAt = updatedAt
    }

    public var settings: NotificationSettings {
        NotificationSettings(enabled: enabled, defaultReminder: defaultReminder,
                             soundEnabled: soundEnabled, quietHoursStart: quietHoursStart,
                             quietHoursEnd: quietHoursEnd, permissionAsked: permissionAsked)
    }
}

/// Wire shape for the archive singleton. The web spells these `enabled` and
/// `archiveAfterDays`; this app stores them as `autoEnabled` and `afterDays`, so the
/// rename lives here rather than being smuggled through `CodingKeys` on the store type.
public struct ArchiveSettingsWire: Codable, Equatable, Sendable {
    public var id: String
    public var enabled: Bool
    public var archiveAfterDays: Int

    public init(autoEnabled: Bool, afterDays: Int) {
        id = "settings"
        enabled = autoEnabled
        archiveAfterDays = afterDays
    }
}

/// Wire shape for app preferences. `smartViewsEnabled` is web-only — this app has no
/// toggle for it (smart views are always reachable from Browse/the sidebar) — so it is
/// written as `true` and ignored on import.
public struct AppPreferencesWire: Codable, Equatable, Sendable {
    public var id: String
    public var pinnedSmartViewIds: [String]
    public var maxPinnedViews: Int
    public var smartViewsEnabled: Bool

    public init(pinnedSmartViewIds: [String], maxPinnedViews: Int) {
        id = "preferences"
        self.pinnedSmartViewIds = pinnedSmartViewIds
        self.maxPinnedViews = maxPinnedViews
        smartViewsEnabled = true
    }
}

extension TaskExport {
    /// GSDModel-local fractional-seconds ISO-8601 coders. GSDModel cannot import GSDStore's
    /// internal `GSDJSON`, so this mirrors its strategy verbatim (design-spec round-trip
    /// fidelity decision). Each call builds its own `ISO8601DateFormatter` instance because
    /// the type is not `Sendable` (matches the GSDJSON pattern).
    private static func makeFormatter() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }

    public static func encode(_ export: TaskExport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(makeFormatter().string(from: date))
        }
        return try encoder.encode(export)
    }

    /// `decoder()` lives on the importer's extension — one definition, shared by both.
    public static func decode(_ data: Data) throws -> TaskExport {
        try decoder().decode(TaskExport.self, from: data)
    }
}
