/// Recurrence kinds. There is intentionally no "yearly" (product spec §5.1, App. A).
public enum RecurrenceType: String, Codable, Sendable, CaseIterable {
    case none, daily, weekly, monthly
}
