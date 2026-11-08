import Foundation
import GSDModel

/// What the watch widget families draw and when they redraw (watch spec 4.5). Pure, so the
/// widget extension only lays out what this returns. The widget reads the snapshot alone; it
/// never adds, removes, or completes a task.
public enum WatchWidgetContent {
    public static let rowLimit = 3
    /// Smart Stack windows per day. Without a cap the widget would claim the stack all day.
    public static let relevanceLimit = 5

    public enum Rectangular: Sendable, Equatable {
        /// No snapshot has reached the watch yet.
        case needsPhone
        case clear
        case rows([String])
    }

    /// `accessoryRectangular`: today's picks in rank order, else the first Do First rows. `nil`
    /// is no snapshot yet, which is not the same as nothing to do.
    public static func rectangular(_ snapshot: WatchSnapshot?, now: Date,
                                   calendar: Calendar, timeZone: TimeZone) -> Rectangular {
        guard let snapshot else { return .needsPhone }
        let picks = WatchOverlay.today(snapshot, pending: [], now: now, timeZone: timeZone).picks
        let lists = WatchOverlay.apply(snapshot, pending: [], now: now, calendar: calendar, timeZone: timeZone)
        let titles = (picks.isEmpty ? lists.doFirst : picks).prefix(rowLimit).map(\.title)
        return titles.isEmpty ? .clear : .rows(titles)
    }

    public struct InlineLine: Sendable, Equatable {
        public var time: Date
        public var title: String
    }

    /// `accessoryInline`: the next task due later today at a time of day ("2:00 PM Call the
    /// dentist"). All-day and already-past tasks don't count. `nil` shows the app name.
    public static func inline(_ snapshot: WatchSnapshot, now: Date, calendar: Calendar) -> InlineLine? {
        // Strictly after `now`: the timeline puts an entry at each due time, and at that entry the
        // task has arrived, so the line moves on to the next one.
        remainingTimed(snapshot, now: now, calendar: calendar, includingNow: false).first
            .map { InlineLine(time: $0.due, title: $0.title) }
    }

    /// Entries: now, each due time left today, and the next local midnight, when "later today"
    /// rolls over for the inline line.
    public static func timelineDates(_ snapshot: WatchSnapshot, now: Date, calendar: Calendar) -> [Date] {
        let midnight = nextMidnight(after: now, calendar: calendar)
        let dues = remainingTimed(snapshot, now: now, calendar: calendar).map(\.due).filter { $0 < midnight }
        var dates = [now]
        for due in dues where dates.last != due { dates.append(due) }
        return dates + [midnight]
    }

    /// Smart Stack windows around the remaining due times: 30 minutes before to 15 after.
    public static func relevanceIntervals(_ snapshot: WatchSnapshot, now: Date, calendar: Calendar) -> [DateInterval] {
        remainingTimed(snapshot, now: now, calendar: calendar).prefix(relevanceLimit).map {
            DateInterval(start: max(now, $0.due.addingTimeInterval(-30 * 60)), end: $0.due.addingTimeInterval(15 * 60))
        }
    }

    private static func remainingTimed(_ snapshot: WatchSnapshot, now: Date, calendar: Calendar,
                                       includingNow: Bool = true) -> [(due: Date, title: String)] {
        let midnight = nextMidnight(after: now, calendar: calendar)
        return snapshot.tasks.compactMap { task -> (due: Date, title: String)? in
            guard let due = task.dueDate, includingNow ? due >= now : due > now, due < midnight,
                  !DueTime.isAllDay(due, calendar: calendar) else { return nil }
            return (due, task.title)
        }.sorted { $0.due < $1.due }
    }

    private static func nextMidnight(after date: Date, calendar: Calendar) -> Date {
        calendar.nextDate(after: date, matching: DateComponents(hour: 0, minute: 0, second: 0),
                          matchingPolicy: .nextTime) ?? date.addingTimeInterval(86_400)
    }
}

/// A one-shot "open Capture" flag in the App Group, set by the Capture control's intent and
/// consumed by the watch app when it comes forward. It stores when it was set and expires, so
/// a tap that never brought the app forward can't open Capture on a launch days later.
public enum WatchCaptureRequest {
    private static let key = "watch.captureRequestedAt"

    /// Longer than this between the tap and the app coming forward, and it was not meant for now.
    public static let maxAge: TimeInterval = 60

    public static func request(in defaults: UserDefaults, now: Date = Date()) {
        defaults.set(now.timeIntervalSince1970, forKey: key)
    }

    public static func consume(from defaults: UserDefaults, now: Date = Date()) -> Bool {
        guard let at = defaults.object(forKey: key) as? Double else { return false }
        defaults.removeObject(forKey: key)
        return now.timeIntervalSince1970 - at <= maxAge
    }
}
