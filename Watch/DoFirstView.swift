import SwiftUI
import GSDModel
import GSDSnapshot

/// The home screen until phase 4 ships top three on Apple (spec 4.1, decision 2): Do First, then
/// "Coming up", the rows `Escalation.evaluate` marks as escalating.
struct DoFirstView: View {
    @Environment(WatchModel.self) private var model
    @State private var capturing = false
    private let rowLimit = 20

    var body: some View {
        let lists = model.lists()
        NavigationStack {
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
                            TaskRow(task: task, escalation: nil)
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
                            TaskRow(task: row.task, escalation: row)
                        }
                    }
                }

                Section { footer(pending: lists.pendingCount) }
            }
            .navigationTitle("GSD")
            .toolbar {
                ToolbarItem(placement: .bottomBar) {
                    Button { capturing = true } label: { Label("Add task", systemImage: "plus") }
                        .accessibilityIdentifier("watch-capture")
                }
            }
            .sheet(isPresented: $capturing) { CaptureView() }
            .safeAreaInset(edge: .bottom) { undoBar }
        }
    }

    @ViewBuilder private func footer(pending: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if pending > 0 {
                Text(pending == 1 ? "1 change waiting for iPhone" : "\(pending) changes waiting for iPhone")
            }
            if model.hasSnapshot {
                Text("Updated \(model.snapshot.generatedAt.formatted(date: .omitted, time: .shortened))")
            }
        }
        .font(.footnote).foregroundStyle(.secondary)
    }

    @ViewBuilder private var undoBar: some View {
        if model.canUndo {
            Button("Undo") { model.undo() }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Undo complete")
        }
    }
}

private struct TaskRow: View {
    @Environment(WatchModel.self) private var model
    let task: WatchTask
    let escalation: WatchEscalatingRow?

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
            if let target = escalation?.escalation.target {
                Button { model.markUrgent(task) } label: { Label("Mark urgent", systemImage: "exclamationmark") }
                    .accessibilityHint(target.markUrgentHint)
                    .tint(.orange)
            }
        }
    }
}
