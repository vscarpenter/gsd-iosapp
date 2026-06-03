import Foundation

/// The lightweight, GRDB-free payload the app writes and the widget reads (spec §4.2).
/// `tasks` is already limited; `totalCount` is the full count of matches (for "+N more").
public struct WidgetSnapshot: Codable, Sendable, Equatable {
    public var generatedAt: Date
    public var tasks: [WidgetTask]
    public var totalCount: Int

    public init(generatedAt: Date, tasks: [WidgetTask], totalCount: Int) {
        self.generatedAt = generatedAt
        self.tasks = tasks
        self.totalCount = totalCount
    }

    /// Shown when no snapshot exists yet or nothing matches.
    public static let empty = WidgetSnapshot(generatedAt: .distantPast, tasks: [], totalCount: 0)

    /// Representative data for the widget gallery / placeholder previews.
    public static let sample = WidgetSnapshot(
        generatedAt: Date(timeIntervalSince1970: 0),
        tasks: [
            WidgetTask(id: "s1", title: "Ship the release", dueDate: nil),
            WidgetTask(id: "s2", title: "Reply to the board", dueDate: nil),
            WidgetTask(id: "s3", title: "Finalize the deck", dueDate: nil),
        ],
        totalCount: 5)
}

/// One row in the widget. Minimal by design — every Today's Focus row is urgent+important.
public struct WidgetTask: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var dueDate: Date?

    public init(id: String, title: String, dueDate: Date?) {
        self.id = id
        self.title = title
        self.dueDate = dueDate
    }
}
