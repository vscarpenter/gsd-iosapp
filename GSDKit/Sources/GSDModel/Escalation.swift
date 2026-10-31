import Foundation

/// Escalation by due date (decisions D-11 and D-12; spec `gsd-taskmanager/tasks/spec-escalation.md`).
/// A pure rule: it flags a task whose due date has come close without the task being marked
/// urgent. It never changes a task. Pinned by the shared 38-case corpus
/// (`EscalationCorpusTests`); the web repo is the authority.
public enum Escalation {
    public enum Reason: String, Sendable, Equatable { case overdue, dueSoon = "due-soon" }
    public enum Target: String, Sendable, Equatable {
        case urgentImportant = "urgent-important"
        case urgentNotImportant = "urgent-not-important"

        public var quadrant: Quadrant {
            switch self {
            case .urgentImportant: return .urgentImportant
            case .urgentNotImportant: return .urgentNotImportant
            }
        }

        /// The hint shown beside Mark urgent; same words as web.
        public var markUrgentHint: String { "Moves to \(quadrant.title)" }

        /// The action's one-line spoken name, hint lowercased to read mid-sentence (same as web).
        public var markUrgentAccessibilityLabel: String { "Mark urgent, moves to \(quadrant.title)" }
    }

    public struct Result: Sendable, Equatable {
        public let escalating: Bool
        /// Local calendar days from `now` to the due date (negative when past); nil with no due date.
        /// Set for every task with a due date, eligible or not, so the due chip can share it.
        public let daysUntilDue: Int?
        public let reason: Reason?
        public let target: Target?
    }

    /// `windowDays` is nil when escalation is Off. Calendar days in `timeZone`, never elapsed
    /// time, and a due time of day does not change the count.
    public static func evaluate(_ task: Task, now: Date, windowDays: Int?, timeZone: TimeZone) -> Result {
        guard let due = task.dueDate else {
            return Result(escalating: false, daysUntilDue: nil, reason: nil, target: nil)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let days = calendar.dateComponents([.day],
                                           from: calendar.startOfDay(for: now),
                                           to: calendar.startOfDay(for: due)).day
        let eligible = !task.completed && task.savedAt == nil && !task.urgent
        guard eligible, let windowDays, let days, days <= windowDays else {
            return Result(escalating: false, daysUntilDue: days, reason: nil, target: nil)
        }
        return Result(escalating: true, daysUntilDue: days,
                      reason: days < 0 ? .overdue : .dueSoon,
                      target: task.important ? .urgentImportant : .urgentNotImportant)
    }
}

extension Escalation {
    /// The marker's accessible name, built from the due chip's own phrases (same as web).
    public static func accessibilityLabel(daysUntilDue days: Int) -> String {
        "Escalating: \(duePhrase(days)), not marked urgent."
    }

    private static func duePhrase(_ days: Int) -> String {
        if days < 0 { return "\(-days) \(days == -1 ? "day" : "days") overdue" }
        if days == 0 { return "due today" }
        return days == 1 ? "due tomorrow" : "due in \(days) days"
    }
}

/// The per-device "Escalate tasks due within" setting (D-12): Off, 1, 2 (default), 3 days, 1 week.
public enum EscalationWindow: Int, CaseIterable, Sendable {
    case off = 0, oneDay = 1, twoDays = 2, threeDays = 3, oneWeek = 7

    public static let `default`: EscalationWindow = .twoDays

    /// Days to hand to `Escalation.evaluate`; nil when Off.
    public var days: Int? { self == .off ? nil : rawValue }
}
