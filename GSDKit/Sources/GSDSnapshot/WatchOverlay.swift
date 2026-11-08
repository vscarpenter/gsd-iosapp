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

    public init(doFirst: [WatchTask], comingUp: [WatchEscalatingRow], pendingCount: Int) {
        self.doFirst = doFirst
        self.comingUp = comingUp
        self.pendingCount = pendingCount
    }

    /// "+N more on iPhone" (spec 6.1): what the phone holds beyond the rows drawn. Counts
    /// against `doFirstTotal` when that is larger, since the snapshot itself is capped.
    public func doFirstMore(rowLimit: Int, doFirstTotal: Int) -> Int {
        max(doFirstTotal, doFirst.count) - min(doFirst.count, rowLimit)
    }
}

public enum WatchOverlay {
    /// Commands whose id is in `snapshot.appliedCommandIDs` have landed, so they drop out.
    /// The rest are applied in `issuedAt` order. Rules run at draw time in `timeZone`.
    public static func apply(
        _ snapshot: WatchSnapshot, pending: [WatchCommand], now: Date,
        calendar: Calendar, timeZone: TimeZone
    ) -> WatchLists {
        let acknowledged = Set(snapshot.appliedCommandIDs)
        let waiting = pending.filter { !acknowledged.contains($0.id) }
            .sorted { $0.issuedAt < $1.issuedAt }

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
            case .snooze, .addToToday, .removeFromToday:
                break    // no list changes; top three joins the overlay with phase 4
            }
        }

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

        return WatchLists(doFirst: doFirst, comingUp: comingUp, pendingCount: waiting.count)
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
