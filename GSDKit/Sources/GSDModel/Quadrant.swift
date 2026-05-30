/// The four Eisenhower quadrants. Declaration order is the canonical
/// display/iteration order Q1→Q4 (product spec §5.8).
public enum Quadrant: String, Codable, Sendable, CaseIterable {
    case urgentImportant = "urgent-important"               // Q1 Do First
    case notUrgentImportant = "not-urgent-important"        // Q2 Schedule
    case urgentNotImportant = "urgent-not-important"        // Q3 Delegate
    case notUrgentNotImportant = "not-urgent-not-important" // Q4 Eliminate

    /// Derives the quadrant from the two axes. The single source of truth —
    /// the persisted column is always written from this, never set directly.
    public init(urgent: Bool, important: Bool) {
        switch (urgent, important) {
        case (true, true): self = .urgentImportant
        case (false, true): self = .notUrgentImportant
        case (true, false): self = .urgentNotImportant
        case (false, false): self = .notUrgentNotImportant
        }
    }

    public var title: String {
        switch self {
        case .urgentImportant: "Do First"
        case .notUrgentImportant: "Schedule"
        case .urgentNotImportant: "Delegate"
        case .notUrgentNotImportant: "Eliminate"
        }
    }
}
