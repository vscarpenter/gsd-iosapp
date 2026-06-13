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

    var body: some View {
        Button { onEdit(task) } label: { Label(String(localized: "Edit"), systemImage: "pencil") }
        Button { actions.duplicate(task) } label: {
            Label(String(localized: "Duplicate"), systemImage: "plus.square.on.square")
        }
        ShareLink(item: task.shareText) {
            Label(String(localized: "Share"), systemImage: "square.and.arrow.up")
        }
        Button { actions.toggle(task) } label: {
            Label(task.completed ? String(localized: "Uncomplete") : String(localized: "Complete"), systemImage: "checkmark")
        }
        if TimeTracking.runningEntry(task.timeEntries) == nil {
            Button(String(localized: "Start Timer")) { actions.startTimer(task) }
        } else {
            Button(String(localized: "Stop Timer")) { actions.stopTimer(task) }
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

    /// Six §6.7 snooze presets — intentionally duplicated (not a shared constant), per the Phase-2 decision.
    private var snoozeMenuPresets: [(String, SnoozePreset)] {
        [(String(localized: "15 minutes"), .fifteenMinutes), (String(localized: "30 minutes"), .thirtyMinutes),
         (String(localized: "1 hour"), .oneHour), (String(localized: "3 hours"), .threeHours),
         (String(localized: "Tomorrow"), .tomorrow), (String(localized: "Next week"), .nextWeek)]
    }
}
