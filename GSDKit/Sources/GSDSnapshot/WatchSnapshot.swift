import Foundation
import GSDModel

/// What the iPhone sends the watch (watch spec section 6.1): a small, GRDB-free slice of the
/// tasks the watch can show. The watch runs the shared `GSDModel` rules on it at draw time.
/// Every field added later must be optional, so a newer iPhone and an older watch app (or the
/// reverse) still decode.
public struct WatchSnapshot: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    /// How many applied command ids the snapshot carries back to the watch.
    public static let appliedCommandCap = 50
    /// Rows per snapshot (spec 6.2).
    public static let taskCap = 100

    public var version: Int
    public var generatedAt: Date
    /// The iPhone's escalation setting; `nil` is Off.
    public var escalationWindowDays: Int?
    public var tasks: [WatchTask]
    /// Every `today-focus` match on the iPhone, for "+N more on iPhone".
    public var doFirstTotal: Int
    public var appliedCommandIDs: [String]

    public init(version: Int = WatchSnapshot.currentVersion, generatedAt: Date,
                escalationWindowDays: Int?, tasks: [WatchTask], doFirstTotal: Int,
                appliedCommandIDs: [String]) {
        self.version = version
        self.generatedAt = generatedAt
        self.escalationWindowDays = escalationWindowDays
        self.tasks = tasks
        self.doFirstTotal = doFirstTotal
        self.appliedCommandIDs = appliedCommandIDs
    }

    public static let empty = WatchSnapshot(generatedAt: .distantPast, escalationWindowDays: nil,
                                            tasks: [], doFirstTotal: 0, appliedCommandIDs: [])
}

/// One row on the wire. Carries exactly the fields the shared rules read.
public struct WatchTask: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var urgent: Bool
    public var important: Bool
    public var dueDate: Date?
    public var createdAt: Date
    public var updatedAt: Date
    public var isRecurring: Bool
    /// Top three fields; `nil` until phase 4 ships on Apple.
    public var focusDate: String?
    public var focusRank: Int?

    public init(id: String, title: String, urgent: Bool, important: Bool, dueDate: Date? = nil,
                createdAt: Date, updatedAt: Date, isRecurring: Bool,
                focusDate: String? = nil, focusRank: Int? = nil) {
        self.id = id
        self.title = title
        self.urgent = urgent
        self.important = important
        self.dueDate = dueDate
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isRecurring = isRecurring
        self.focusDate = focusDate
        self.focusRank = focusRank
    }

    public init(_ task: Task) {
        self.init(id: task.id, title: task.title, urgent: task.urgent, important: task.important,
                  dueDate: task.dueDate, createdAt: task.createdAt, updatedAt: task.updatedAt,
                  isRecurring: task.recurrence != .none)
    }

    /// The model task the shared rules run on. Every field the row leaves out takes
    /// `Task.init`'s default; the snapshot only ever holds active, unsaved rows.
    public var asTask: Task {
        Task(id: id, title: title, urgent: urgent, important: important,
             createdAt: createdAt, updatedAt: updatedAt, dueDate: dueDate,
             recurrence: isRecurring ? .daily : .none)
    }
}
