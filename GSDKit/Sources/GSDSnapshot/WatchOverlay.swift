import Foundation
import GSDModel

/// An escalating row with the shared rule's answer, so the screen can draw the marker text and
/// the Mark urgent hint without running the rule again.
public struct WatchEscalatingRow: Sendable, Equatable, Identifiable {
    public var task: WatchTask
    public var escalation: Escalation.Result
    public var id: String { task.id }
}

/// What the watch draws: the snapshot with the watch's pending commands applied on top.
public struct WatchLists: Sendable, Equatable {
    /// `today-focus` rows, in the iPhone widget's order.
    public var doFirst: [WatchTask]
    /// Rows `Escalation.evaluate` marks as escalating, soonest first.
    public var comingUp: [WatchEscalatingRow]
    /// Commands not yet acknowledged by the iPhone, for "2 changes waiting for iPhone".
    public var pendingCount: Int
    /// Do First rows the pending commands added (positive) or removed (negative).
    public var doFirstDelta: Int

    public init(doFirst: [WatchTask], comingUp: [WatchEscalatingRow], pendingCount: Int, doFirstDelta: Int = 0) {
        self.doFirst = doFirst
        self.comingUp = comingUp
        self.pendingCount = pendingCount
        self.doFirstDelta = doFirstDelta
    }

    /// "+N more on iPhone" (spec 6.1): what the phone holds beyond the rows drawn. Counts
    /// against `doFirstTotal` (adjusted for pending commands) when that is larger, since the snapshot itself is capped.
    public func doFirstMore(rowLimit: Int, doFirstTotal: Int) -> Int {
        max(doFirstTotal + doFirstDelta, doFirst.count) - min(doFirst.count, rowLimit)
    }
}

public enum WatchOverlay {
    /// Commands whose id is in `snapshot.appliedCommandIDs` have landed, so they drop out.
    /// The rest are applied in `issuedAt` order. Rules run at draw time in `timeZone`.
    public static func apply(
        _ snapshot: WatchSnapshot, pending: [WatchCommand], now: Date,
        calendar: Calendar, timeZone: TimeZone
    ) -> WatchLists {
        let waiting = waitingCommands(snapshot, pending)
        let rows = overlaidRows(snapshot, waiting: waiting, now: now, timeZone: timeZone)

        let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let tasks = rows.map(\.asTask)

        let focusCriteria = BuiltInSmartViews.all
            .first { $0.id == WidgetSnapshotBuilder.todaysFocusViewID }!.criteria
        let doFirst = TaskFilter.apply(focusCriteria, to: tasks, now: now, calendar: calendar)
            .compactMap { byID[$0.id] }

        let comingUp = rows.compactMap { row -> WatchEscalatingRow? in
            let result = Escalation.evaluate(row.asTask, now: now,
                                             windowDays: snapshot.escalationWindowDays, timeZone: timeZone)
            return result.escalating ? WatchEscalatingRow(task: row, escalation: result) : nil
        }.sorted { ($0.escalation.daysUntilDue ?? 0, $0.task.createdAt) < ($1.escalation.daysUntilDue ?? 0, $1.task.createdAt) }

        // The snapshot's `doFirstTotal` knows nothing of pending commands, so carry how many Do First
        // rows they added or removed, and "+N more" stays honest.
        let baseline = waiting.isEmpty ? doFirst.count
            : apply(snapshot, pending: [], now: now, calendar: calendar, timeZone: timeZone).doFirst.count
        return WatchLists(doFirst: doFirst, comingUp: comingUp, pendingCount: waiting.count,
                          doFirstDelta: doFirst.count - baseline)
    }

    private static func waitingCommands(_ snapshot: WatchSnapshot, _ pending: [WatchCommand]) -> [WatchCommand] {
        let acknowledged = Set(snapshot.appliedCommandIDs)
        return pending.filter { !acknowledged.contains($0.id) }.sorted { $0.issuedAt < $1.issuedAt }
    }

    private static func overlaidRows(_ snapshot: WatchSnapshot, waiting: [WatchCommand],
                                     now: Date, timeZone: TimeZone) -> [WatchTask] {
        var rows = snapshot.tasks
        var hidden: [String: WatchTask] = [:]    // completed by a pending command, restorable by a reopen
        for command in waiting {
            switch command.kind {
            case .complete(let id):
                if let i = rows.firstIndex(where: { $0.id == id }) { hidden[id] = rows.remove(at: i) }
            case .reopen(let id):
                if let row = hidden.removeValue(forKey: id) { rows.append(row) }
            case .markUrgent(let id):
                if let i = rows.firstIndex(where: { $0.id == id }), !rows[i].urgent { rows[i].urgent = true }
            case .capture(let text, let quadrant):
                let title = WatchCommandPlan.parseCapture(text).title
                guard !title.isEmpty else { continue }
                rows.append(WatchTask(id: "pending-\(command.id)", title: title,
                                      urgent: quadrant.isUrgent, important: quadrant.isImportant,
                                      createdAt: command.issuedAt, updatedAt: command.issuedAt,
                                      isRecurring: false))
            case .addToToday(let id):
                guard let i = rows.firstIndex(where: { $0.id == id }),
                      let rank = TopThree.nextRank(rows.map(\.asTask), now: now, timeZone: timeZone) else { continue }
                rows[i].focusDate = TopThree.localDate(now, timeZone: timeZone)
                rows[i].focusRank = rank
            case .removeFromToday(let id):
                if let i = rows.firstIndex(where: { $0.id == id }) { rows[i].focusDate = nil; rows[i].focusRank = nil }
            case .snooze:
                break    // no list changes
            }
        }
        return rows
    }

    /// The Today screen (spec 4.1): `TopThree`'s answers on the snapshot with pending commands
    /// applied. No picks means the first three suggestions, each offered with "Add to today".
    public static func today(_ snapshot: WatchSnapshot, pending: [WatchCommand], now: Date,
                             timeZone: TimeZone) -> WatchToday {
        let rows = overlaidRows(snapshot, waiting: waitingCommands(snapshot, pending), now: now, timeZone: timeZone)
        let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let tasks = rows.map(\.asTask)
        let picks = TopThree.todaysPicks(tasks, now: now, timeZone: timeZone).picks.compactMap { byID[$0] }
        let suggestions = picks.isEmpty
            ? TopThree.suggest(tasks, now: now, windowDays: snapshot.escalationWindowDays, timeZone: timeZone)
                .prefix(TopThree.maxPicks).compactMap { byID[$0] }
            : []
        return WatchToday(picks: picks, suggestions: Array(suggestions), canAdd: picks.count < TopThree.maxPicks)
    }

    public enum UndoOutcome: Sendable, Equatable {
        /// The `complete` command is still in the outbox; drop it and nothing was ever applied.
        case removeFromOutbox(commandID: String)
        /// The command already left; queue a `reopen`.
        case queueReopen(taskID: String)
        /// A repeating task whose command already left: reopening would leave the spawned next
        /// instance open beside it, so offer no Undo (watch spec section 10, item 8).
        case unavailable
    }

    public static func undoComplete(commandID: String, of task: WatchTask, outbox: [WatchCommand]) -> UndoOutcome {
        if outbox.contains(where: { $0.id == commandID }) { return .removeFromOutbox(commandID: commandID) }
        return task.isRecurring ? .unavailable : .queueReopen(taskID: task.id)
    }
}
