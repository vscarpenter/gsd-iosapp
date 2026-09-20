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
    /// One row per due state (overdue, today, later), relative to now, so the gallery preview
    /// shows the widget's shape markers rather than three identical rows.
    public static var sample: WidgetSnapshot {
        let now = Date()
        let day: TimeInterval = 86_400
        return WidgetSnapshot(
            generatedAt: now,
            tasks: [
                WidgetTask(id: "s1", title: "Ship the release", dueDate: now.addingTimeInterval(-day)),
                WidgetTask(id: "s2", title: "Reply to the board", dueDate: now),
                WidgetTask(id: "s3", title: "Finalize the deck", dueDate: now.addingTimeInterval(3 * day)),
            ],
            totalCount: 5)
    }
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
