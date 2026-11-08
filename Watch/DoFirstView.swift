import SwiftUI
import GSDModel
import GSDSnapshot

/// Do First, then "Coming up", the rows `Escalation.evaluate` marks as escalating (spec 4.2).
/// One page below Today, which is the home screen now that top three is on Apple.
struct DoFirstView: View {
    @Environment(WatchModel.self) private var model
    /// Whether this page is the one on screen, so only it answers a tapped reminder.
    let active: Bool
    @State private var capturing = false
    private let rowLimit = 20

    var body: some View {
        let lists = model.lists()
        let today = model.today()
        let pickIDs = Set(today.picks.map(\.id))
        NavigationStack {
          ScrollViewReader { proxy in
            List {
                if !model.hasSnapshot {
                    Text("Open GSD on your iPhone to load your tasks.")
                        .foregroundStyle(.secondary)
                } else if lists.doFirst.isEmpty && lists.comingUp.isEmpty {
                    Text("Clear for now")
                        .foregroundStyle(.secondary)
                }

                if !lists.doFirst.isEmpty {
                    Section("Do First") {
                        ForEach(lists.doFirst.prefix(rowLimit)) { task in
                            TaskRow(task: task, escalation: nil, canAddToToday: today.canAdd && !pickIDs.contains(task.id))
                        }
                        let more = lists.doFirstMore(rowLimit: rowLimit, doFirstTotal: model.snapshot.doFirstTotal)
                        if more > 0 {
                            Text("+\(more) more on iPhone")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }

                if !lists.comingUp.isEmpty {
                    Section("Coming up") {
                        ForEach(lists.comingUp.prefix(rowLimit)) { row in
                            TaskRow(task: row.task, escalation: row, canAddToToday: today.canAdd && !pickIDs.contains(row.task.id))
                        }
                    }
                }

                Section { WatchFooter(pending: lists.pendingCount) }
            }
            .navigationTitle("GSD")
            .toolbar {
                ToolbarItem(placement: .bottomBar) {
                    Button { capturing = true } label: { Label("Add task", systemImage: "plus") }
                        .accessibilityIdentifier("watch-capture")
                }
            }
            .sheet(isPresented: $capturing) { CaptureView() }
            .onChange(of: model.captureRequested, initial: true) { _, requested in
                if requested { capturing = true; model.captureRequested = false }
            }
            .safeAreaInset(edge: .bottom) { WatchUndoBar() }
            // A tapped reminder scrolls to the task's row (spec 4.4).
            .onChange(of: model.openedTaskID, initial: true) { _, _ in openTask(proxy) }
            .onChange(of: active) { _, _ in openTask(proxy) }
          }
        }
    }

    /// A task past the first 20 rows isn't in the list, so this does nothing for it.
    private func openTask(_ proxy: ScrollViewProxy) {
        guard active, let id = model.openedTaskID else { return }
        proxy.scrollTo(id, anchor: .center)
        model.consumeOpenedTask()
    }
}

private struct TaskRow: View {
    @Environment(WatchModel.self) private var model
    let task: WatchTask
    let escalation: WatchEscalatingRow?
    /// False when three picks are in, or the row is already one: "Add to today" is hidden (spec 4.1).
    let canAddToToday: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(task.title)
            if let days = escalation?.escalation.daysUntilDue {
                Text(Escalation.accessibilityLabel(daysUntilDue: days))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .swipeActions(edge: .leading) {
            Button { model.complete(task) } label: { Label("Complete", systemImage: "checkmark") }
                .tint(.green)
        }
        .swipeActions(edge: .trailing) {
            if canAddToToday {
                Button { model.addToToday(task) } label: { Label("Add to today", systemImage: "sun.max") }
            }
            if let target = escalation?.escalation.target {
                Button { model.markUrgent(task) } label: { Label("Mark urgent", systemImage: "exclamationmark") }
                    .accessibilityHint(target.markUrgentHint)
                    .tint(.orange)
            }
        }
    }
}
