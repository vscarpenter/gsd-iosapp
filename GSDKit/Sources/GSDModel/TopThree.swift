import Foundation

/// Top three (decision D-13; spec `gsd-taskmanager/tasks/spec-top-three.md`): the pure rules for
/// "up to three picks for today". Nothing here writes. Callers apply the writes `tidy` returns
/// through the ordinary edit path. Pinned by the shared 123-case corpus (`TopThreeCorpusTests`);
/// the web repo is the authority.
public enum TopThree {
    public static let maxPicks = 3
    /// Carry-over looks back at most this many local days (spec 3.4).
    public static let carryOverDays = 7

    // MARK: - Dates

    /// Today as `YYYY-MM-DD` in `timeZone`. `focusDate` is plain text, never an instant, so it is
    /// compared as text with this value.
    public static func localDate(_ now: Date, timeZone: TimeZone) -> String {
        let c = calendar(timeZone).dateComponents([.year, .month, .day], from: now)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private static func calendar(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// Whole days from `earlier` to `later`, both real `YYYY-MM-DD` dates. Counted on the calendar,
    /// not in elapsed time, so a clock change never moves the count.
    private static func daysBetween(_ earlier: String, _ later: String) -> Int? {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt
        guard let a = parse(earlier, calendar: utc), let b = parse(later, calendar: utc) else { return nil }
        return utc.dateComponents([.day], from: a, to: b).day
    }

    /// A real calendar date in strict `YYYY-MM-DD` form, or nil. Rejects `2026-02-30`, `2026-11-4`,
    /// and `2026-11-04T00:00`.
    private static func parse(_ text: String, calendar: Calendar) -> Date? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              text.utf8.allSatisfy({ $0 == UInt8(ascii: "-") || ($0 >= 48 && $0 <= 57) }),
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              let date = calendar.date(from: DateComponents(year: y, month: m, day: d))
        else { return nil }
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        return back.year == y && back.month == m && back.day == d ? date : nil
    }

    private static func isRealDate(_ text: String) -> Bool {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt
        return parse(text, calendar: utc) != nil
    }

    // MARK: - Field validity (spec 3.5)

    /// The pair counts only when the date is real and the rank is 1 to 3. Anything else is unset,
    /// both fields together, so a bad pick never costs the user the task.
    public static func validated(focusDate: String?, focusRank: Int?) -> (focusDate: String?, focusRank: Int?) {
        guard let focusDate, let focusRank, (1...maxPicks).contains(focusRank), isRealDate(focusDate)
        else { return (nil, nil) }
        return (focusDate, focusRank)
    }

    /// Wire to client. The wire writes `""` and `0` for unset, and a record from before the fields
    /// existed carries neither. A fractional rank is unset.
    public static func fromWire(focusDate: String?, focusRank: Double?) -> (focusDate: String?, focusRank: Int?) {
        guard let focusRank, let rank = Int(exactly: focusRank) else { return (nil, nil) }
        return validated(focusDate: focusDate, focusRank: rank)
    }

    /// Client to wire. PocketBase never stores a null number, so unset is `""` and `0`.
    public static func toWire(focusDate: String?, focusRank: Int?) -> (focusDate: String, focusRank: Int) {
        let pair = validated(focusDate: focusDate, focusRank: focusRank)
        return (pair.focusDate ?? "", pair.focusRank ?? 0)
    }

    /// What a push sends for the focus fields (C4-6): the task's current row, never the queued
    /// payload, which can be older than the row. `current` is nil when the row has left the active
    /// store, and the result is then nil, meaning both keys stay off the wire so the server keeps
    /// its value. The payload is accepted only to show it is ignored.
    public static func pushFocus(payload: (focusDate: String?, focusRank: Int?),
                                 current: (focusDate: String?, focusRank: Int?)?)
        -> (focusDate: String, focusRank: Int)? {
        guard let current else { return nil }
        return toWire(focusDate: current.focusDate, focusRank: current.focusRank)
    }

    // MARK: - Today's picks (spec 3.1)

    public struct Picks: Sendable, Equatable {
        public let picks: [String]
        public let overflow: [String]
        public let needsTidy: Bool
    }

    /// Eligible means active, not completed, and not Saved. The caller passes active-store rows
    /// only, because archived and trashed rows live in their own stores.
    private static func isEligible(_ task: Task) -> Bool { !task.completed && task.savedAt == nil }

    /// Eligible tasks picked for `today`, in the two-device conflict order: lowest rank, then newest
    /// `updatedAt`, then `id` ascending.
    private static func ordered(_ tasks: [Task], onDate date: String) -> [Task] {
        tasks
            .filter { task in
                guard isEligible(task), task.focusDate == date, let rank = task.focusRank else { return false }
                return (1...maxPicks).contains(rank)
            }
            .sorted { a, b in
                if a.focusRank != b.focusRank { return (a.focusRank ?? 0) < (b.focusRank ?? 0) }
                if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
                return a.id < b.id
            }
    }

    public static func todaysPicks(_ tasks: [Task], now: Date, timeZone: TimeZone) -> Picks {
        let list = ordered(tasks, onDate: localDate(now, timeZone: timeZone))
        let ranks = list.compactMap(\.focusRank)
        return Picks(picks: list.prefix(maxPicks).map(\.id),
                     overflow: list.dropFirst(maxPicks).map(\.id),
                     needsTidy: list.count > maxPicks || Set(ranks).count < ranks.count)
    }

    // MARK: - Writes (spec 3.2)

    /// The lowest rank from 1 to 3 that no current pick uses, or nil when none is free.
    public static func nextRank(_ tasks: [Task], now: Date, timeZone: TimeZone) -> Int? {
        let used = Set(ordered(tasks, onDate: localDate(now, timeZone: timeZone)).compactMap(\.focusRank))
        return (1...maxPicks).first { !used.contains($0) }
    }

    public struct Write: Sendable, Equatable {
        public let id: String
        /// Nil with a nil rank clears the pick.
        public let focusDate: String?
        public let focusRank: Int?
    }

    /// What accepting the "Tidy up?" offer writes. The first three get ranks 1 to 3, overflow rows
    /// are cleared, and rows already correct are left out. Nothing to tidy writes nothing: a gap in
    /// ranks is no conflict.
    public static func tidy(_ tasks: [Task], now: Date, timeZone: TimeZone) -> [Write] {
        let today = localDate(now, timeZone: timeZone)
        guard todaysPicks(tasks, now: now, timeZone: timeZone).needsTidy else { return [] }
        return ordered(tasks, onDate: today).enumerated().compactMap { index, task in
            if index >= maxPicks { return Write(id: task.id, focusDate: nil, focusRank: nil) }
            return task.focusRank == index + 1 ? nil : Write(id: task.id, focusDate: today, focusRank: index + 1)
        }
    }

    // MARK: - Suggestions (spec 3.3)

    /// Eligible tasks that aren't today's picks, in four groups: overdue Q1, escalating, Q1 with a
    /// due date, and the rest of Q1. Delegate tasks and non-escalating Schedule tasks never appear.
    /// `windowDays` is nil when escalation is Off.
    public static func suggest(_ tasks: [Task], now: Date, windowDays: Int?, timeZone: TimeZone) -> [String] {
        let picked = Set(todaysPicks(tasks, now: now, timeZone: timeZone).picks)
        var overdue: [Task] = [], escalating: [Task] = [], dated: [Task] = [], undated: [Task] = []
        for task in tasks where isEligible(task) && !picked.contains(task.id) {
            let result = Escalation.evaluate(task, now: now, windowDays: windowDays, timeZone: timeZone)
            let isQ1 = task.urgent && task.important
            if isQ1, let days = result.daysUntilDue, days < 0 {
                overdue.append(task)
            } else if result.escalating {
                escalating.append(task)
            } else if isQ1, task.dueDate != nil {
                dated.append(task)
            } else if isQ1 {
                undated.append(task)
            }
        }
        let byDue: (Task, Task) -> Bool = { a, b in
            if a.dueDate != b.dueDate { return (a.dueDate ?? .distantFuture) < (b.dueDate ?? .distantFuture) }
            if a.important != b.important { return a.important }
            return a.id < b.id
        }
        let byAge: (Task, Task) -> Bool = { a, b in
            a.createdAt != b.createdAt ? a.createdAt < b.createdAt : a.id < b.id
        }
        return (overdue.sorted(by: byDue) + escalating.sorted(by: byDue)
                + dated.sorted(by: byDue) + undated.sorted(by: byAge)).map(\.id)
    }

    // MARK: - Carry-over (spec 3.4)

    public struct CarryOver: Sendable, Equatable {
        public let fromDate: String?
        public let ids: [String]
    }

    /// An offer, never a write: the latest earlier date, at most seven local days back, that still
    /// has an eligible pick, with up to three of that date's tasks in conflict order.
    public static func carryOver(_ tasks: [Task], now: Date, timeZone: TimeZone) -> CarryOver {
        let today = localDate(now, timeZone: timeZone)
        var latest: String?
        for task in tasks where isEligible(task) {
            guard let date = task.focusDate, let rank = task.focusRank, (1...maxPicks).contains(rank),
                  let back = daysBetween(date, today), (1...carryOverDays).contains(back)
            else { continue }
            if latest.map({ date > $0 }) ?? true { latest = date }
        }
        guard let latest else { return CarryOver(fromDate: nil, ids: []) }
        return CarryOver(fromDate: latest, ids: ordered(tasks, onDate: latest).prefix(maxPicks).map(\.id))
    }

    /// The words over the carry-over offer: one day back is "From yesterday", two to six days back
    /// is the weekday ("From Friday"), and seven days back is "From a week ago", because the weekday
    /// would match today's. `carryOver` only offers dates one to seven days back, so these are all
    /// the cases.
    public static func carryOverLabel(from date: String, today: String, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let back = daysBetween(date, today) ?? 1
        if back <= 1 { return String(localized: "From yesterday") }
        if back >= carryOverDays { return String(localized: "From a week ago") }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt
        let name = parse(date, calendar: utc).map { day -> String in
            let formatter = DateFormatter()
            formatter.calendar = utc
            formatter.timeZone = .gmt
            formatter.setLocalizedDateFormatFromTemplate("EEEE")
            return formatter.string(from: day)
        } ?? ""
        return String(localized: "From \(name)")
    }

    // MARK: - Pull merge (spec 6, C4-4)

    /// The fields a pull compares. Dates are instants; `focusDate` is text.
    public struct SyncRow: Sendable, Equatable {
        public var updatedAt: Date
        public var focusDate: String?
        public var focusRank: Int?
        public var savedAt: Date?

        public init(updatedAt: Date, focusDate: String? = nil, focusRank: Int? = nil, savedAt: Date? = nil) {
            self.updatedAt = updatedAt
            self.focusDate = focusDate
            self.focusRank = focusRank
            self.savedAt = savedAt
        }
    }

    public enum PullAction: String, Sendable, Equatable {
        case insert, none
        case takeRemote = "take-remote"
        case copyFields = "copy-fields"
    }

    public struct PullResult: Sendable, Equatable {
        public let action: PullAction
        public let conflict: Bool
        public let row: SyncRow?
    }

    /// The contract in which each field was first read. A stored version below it, or none at all,
    /// means the field is still copyable from the server.
    public static let focusFirstReadContract = 4
    public static let savedAtFirstReadContract = 3

    /// Which fields a build that never read them may copy from the server onto a row. `focus` is the
    /// pair (`focusDate` and `focusRank` together); `savedAt` is its own. Mirrors web's
    /// `unreadFieldsToCopy`, so the sync backfill and `pullMerge` share one decision.
    public struct UnreadFields: Sendable, Equatable {
        public let focus: Bool
        public let savedAt: Bool
        public var any: Bool { focus || savedAt }
    }

    /// A field is copyable when the stored contract version is below the one that first read it
    /// (a missing version is below every version), the local value is unset, and the remote's is set.
    /// A null `savedAt` on a build that already read it is a real Return, so it is never copied.
    public static func unreadFieldsToCopy(storedContract: Int?, local: SyncRow, remote: SyncRow) -> UnreadFields {
        let stored = storedContract ?? 0
        return UnreadFields(
            focus: stored < focusFirstReadContract && local.focusDate == nil && remote.focusDate != nil,
            savedAt: stored < savedAtFirstReadContract && local.savedAt == nil && remote.savedAt != nil)
    }

    /// How one pulled record meets the local row. `tombstoned` means a local archive or trash row
    /// exists and the remote isn't strictly newer than it. Ordinary pulls are strictly-newer-wins.
    /// During a backfill (stored version below a field's first read), a row that is not older
    /// locally also takes the fields it never knew about, and nothing else, without queuing a push
    /// or counting a conflict.
    public static func pullMerge(storedContract: Int?, tombstoned: Bool, local: SyncRow?, remote: SyncRow) -> PullResult {
        guard let local else {
            return tombstoned ? PullResult(action: .none, conflict: false, row: nil)
                              : PullResult(action: .insert, conflict: false, row: remote)
        }
        if remote.updatedAt > local.updatedAt {
            return PullResult(action: .takeRemote, conflict: true, row: remote)
        }
        let copy = unreadFieldsToCopy(storedContract: storedContract, local: local, remote: remote)
        let (copyFocus, copySaved) = (copy.focus, copy.savedAt)
        guard copyFocus || copySaved else { return PullResult(action: .none, conflict: false, row: local) }
        if remote.updatedAt == local.updatedAt {
            return PullResult(action: .takeRemote, conflict: false, row: remote)
        }
        var merged = local
        if copyFocus { merged.focusDate = remote.focusDate; merged.focusRank = remote.focusRank }
        if copySaved { merged.savedAt = remote.savedAt }
        return PullResult(action: .copyFields, conflict: false, row: merged)
    }
}
