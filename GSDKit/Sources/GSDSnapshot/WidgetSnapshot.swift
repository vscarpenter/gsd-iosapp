import Foundation
import GSDModel

/// The lightweight, GRDB-free payload the app writes and the widget reads (spec §4.2).
/// `tasks` is already limited; `totalCount` is the full count of matches (for "+N more").
public struct WidgetSnapshot: Codable, Sendable, Equatable {
    public var generatedAt: Date
    public var tasks: [WidgetTask]
    public var totalCount: Int
    /// Top three (spec-top-three section 9): the local `YYYY-MM-DD` the picks below were made for,
    /// and the picks in rank order. Both are absent from a snapshot written before top three, so
    /// an old snapshot still decodes. Read through `visibleFocusTasks(at:timeZone:)`, never directly.
    public var focusDate: String?
    public var focusTasks: [WidgetTask]

    public init(generatedAt: Date, tasks: [WidgetTask], totalCount: Int,
                focusDate: String? = nil, focusTasks: [WidgetTask] = []) {
        self.generatedAt = generatedAt
        self.tasks = tasks
        self.totalCount = totalCount
        self.focusDate = focusDate
        self.focusTasks = focusTasks
    }

    private enum CodingKeys: String, CodingKey { case generatedAt, tasks, totalCount, focusDate, focusTasks }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = try c.decode(Date.self, forKey: .generatedAt)
        tasks = try c.decode([WidgetTask].self, forKey: .tasks)
        totalCount = try c.decode(Int.self, forKey: .totalCount)
        focusDate = try c.decodeIfPresent(String.self, forKey: .focusDate)
        focusTasks = try c.decodeIfPresent([WidgetTask].self, forKey: .focusTasks) ?? []
    }

    /// The widget draws picks only while the snapshot's date is the local date it is drawing on.
    /// Neither widget redraws at midnight by itself, so a snapshot written yesterday must not show
    /// yesterday's picks today. Nil means show the existing Today's Focus list.
    public func visibleFocusTasks(at date: Date, timeZone: TimeZone = .current) -> [WidgetTask]? {
        guard let focusDate, !focusTasks.isEmpty,
              focusDate == TopThree.localDate(date, timeZone: timeZone)
        else { return nil }
        return focusTasks
    }

    /// The next local midnight after `date`, when the widget must draw again.
    public static func nextLocalMidnight(after date: Date, timeZone: TimeZone = .current) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.nextDate(after: date, matching: DateComponents(hour: 0, minute: 0, second: 0),
                                 matchingPolicy: .nextTime) ?? date.addingTimeInterval(86_400)
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
