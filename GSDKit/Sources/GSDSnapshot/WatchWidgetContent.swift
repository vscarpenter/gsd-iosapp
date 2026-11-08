import Foundation
import GSDModel

/// What the watch widget families draw and when they redraw (watch spec 4.5). Pure, so the
/// widget extension only lays out what this returns. The widget reads the snapshot alone; it
/// never adds, removes, or completes a task.
public enum WatchWidgetContent {
    public static let rowLimit = 3
    /// Smart Stack windows per day. Without a cap the widget would claim the stack all day.
    public static let relevanceLimit = 5

    /// `accessoryRectangular`: today's picks in rank order when any are dated the local today,
    /// else the first Do First rows. Empty means the widget says "Clear for now".
    public static func rectangularTitles(_ snapshot: WatchSnapshot, now: Date,
                                         calendar: Calendar, timeZone: TimeZone) -> [String] {
        let today = TopThree.localDate(now, timeZone: timeZone)
        let picks = snapshot.tasks
            .filter { $0.focusDate == today && $0.focusRank != nil }
            .sorted { ($0.focusRank ?? 0) < ($1.focusRank ?? 0) }
        if !picks.isEmpty { return picks.prefix(rowLimit).map(\.title) }
        let lists = WatchOverlay.apply(snapshot, pending: [], now: now, calendar: calendar, timeZone: timeZone)
        return lists.doFirst.prefix(rowLimit).map(\.title)
    }

    public struct InlineLine: Sendable, Equatable {
        public var time: Date
        public var title: String
    }

    /// `accessoryInline`: the next task due later today at a time of day ("2:00 PM Call the
    /// dentist"). All-day and already-past tasks don't count. `nil` shows the app name.
    public static func inline(_ snapshot: WatchSnapshot, now: Date, calendar: Calendar) -> InlineLine? {
        remainingTimed(snapshot, now: now, calendar: calendar).first.map { InlineLine(time: $0.due, title: $0.title) }
    }

    /// Entries: now, each due time left today, and the next local midnight, which is when a
    /// pick dated today stops being today's.
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

    private static func remainingTimed(_ snapshot: WatchSnapshot, now: Date,
                                       calendar: Calendar) -> [(due: Date, title: String)] {
        let midnight = nextMidnight(after: now, calendar: calendar)
        return snapshot.tasks.compactMap { task -> (due: Date, title: String)? in
            guard let due = task.dueDate, due >= now, due < midnight,
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
/// consumed by the watch app when it comes forward.
public enum WatchCaptureRequest {
    private static let key = "watch.captureRequested"

    public static func request(in defaults: UserDefaults) { defaults.set(true, forKey: key) }

    public static func consume(from defaults: UserDefaults) -> Bool {
        guard defaults.bool(forKey: key) else { return false }
        defaults.removeObject(forKey: key)
        return true
    }
}
