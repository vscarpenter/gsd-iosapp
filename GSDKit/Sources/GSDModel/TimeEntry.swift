import Foundation

/// A single tracked interval embedded in a Task (product spec §5.3).
/// `endedAt` is nil while the timer runs. Max 1000 per task.
public struct TimeEntry: Codable, Sendable, Identifiable, Equatable {
    public var id: String          // nanoid length 8
    public var startedAt: Date
    public var endedAt: Date?      // nil while running
    public var notes: String?      // 0–200 chars

    public init(id: String, startedAt: Date, endedAt: Date? = nil, notes: String? = nil) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.notes = notes
    }
}
