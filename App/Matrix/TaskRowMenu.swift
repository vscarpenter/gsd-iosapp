import SwiftUI
import GSDModel
import GSDStore

/// The full per-task action set, shared by the iPhone long-press context menu,
/// the iPad swipe-reveal menu, and the always-visible `⋯` button on the card —
/// so the three entry points can never drift apart.
struct TaskRowMenu: View {
    let task: Task
    let actions: TaskActions
    var onEdit: (Task) -> Void
    @Environment(\.escalationWindow) private var escalationWindow
    @Environment(TaskStore.self) private var store

    var body: some View {
        Button { onEdit(task) } label: { Label(String(localized: "Edit"), systemImage: "pencil") }
        Button { actions.duplicate(task) } label: {
            Label(String(localized: "Duplicate"), systemImage: "plus.square.on.square")
        }
        if !task.completed && !task.isSaved {
            Button { actions.moveToSaved(task) } label: {
                Label(String(localized: "Move to Saved"), systemImage: "bookmark")
            }
        }
        ShareLink(item: task.shareText) {
            Label(String(localized: "Share"), systemImage: "square.and.arrow.up")
        }
        Button { actions.toggle(task) } label: {
            Label(task.completed ? String(localized: "Uncomplete") : String(localized: "Complete"), systemImage: "checkmark")
        }
        todayItems
        if TimeTracking.runningEntry(task.timeEntries) == nil {
            Button(String(localized: "Start Timer")) { actions.startTimer(task) }
        } else {
            Button(String(localized: "Stop Timer")) { actions.stopTimer(task) }
        }
        if let target = task.escalation(window: escalationWindow).target {
            Button { actions.markUrgent(task, target: target) } label: {
                Label(String(localized: "Mark urgent"), systemImage: "arrow.up")
                Text(target.markUrgentHint)
            }
        }
        Menu(String(localized: "Snooze")) {
            ForEach(snoozeMenuPresets.indices, id: \.self) { i in
                Button(snoozeMenuPresets[i].0) { actions.snooze(task, by: snoozeMenuPresets[i].1) }
            }
        }
        Menu(String(localized: "Move to")) {
            ForEach(Quadrant.allCases, id: \.self) { q in
                Button(q.title) { actions.move(task, to: q) }
            }
        }
        Button(role: .destructive) { actions.delete(task) } label: { Label(String(localized: "Delete"), systemImage: "trash") }
    }

    /// "Add to today" or "Remove from today", plus Move up and Move down for a pick. A full day
    /// shows "Today is full", disabled. Completed and Saved tasks can't be picked.
    @ViewBuilder private var todayItems: some View {
        let picks = TopThree.todaysPicks(store.tasks, now: Date(), timeZone: .current)
        if let index = picks.picks.firstIndex(of: task.id) {
            Button { actions.removeFromToday(task) } label: {
                Label(String(localized: "Remove from today"), systemImage: "sun.max")
            }
            if !picks.needsTidy {
                if index > 0 {
                    Button { actions.moveInToday(task, by: -1) } label: {
                        Label(String(localized: "Move up"), systemImage: "arrow.up")
                    }
                }
                if index < picks.picks.count - 1 {
                    Button { actions.moveInToday(task, by: 1) } label: {
                        Label(String(localized: "Move down"), systemImage: "arrow.down")
                    }
                }
            }
        } else if !task.completed && !task.isSaved {
            if TopThree.nextRank(store.tasks, now: Date(), timeZone: .current) != nil {
                Button { actions.addToToday(task) } label: {
                    Label(String(localized: "Add to today"), systemImage: "sun.max")
                }
            } else {
                Button {} label: { Label(String(localized: "Today is full"), systemImage: "sun.max") }
                    .disabled(true)
            }
        }
    }

    /// Six §6.7 snooze presets — intentionally duplicated (not a shared constant), per the Phase-2 decision.
    private var snoozeMenuPresets: [(String, SnoozePreset)] {
        [(String(localized: "15 minutes"), .fifteenMinutes), (String(localized: "30 minutes"), .thirtyMinutes),
         (String(localized: "1 hour"), .oneHour), (String(localized: "3 hours"), .threeHours),
         (String(localized: "Tomorrow"), .tomorrow), (String(localized: "Next week"), .nextWeek)]
    }
}
