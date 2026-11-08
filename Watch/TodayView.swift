import SwiftUI
import GSDModel
import GSDSnapshot

/// The home screen (spec 4.1). With picks: rows in rank order, each with a complete control. With
/// none: "Pick up to three for today" and the first three suggestions, each with "Add to today".
/// `TopThree` decides everything; this view draws it. Carry-over and Tidy stay on the iPhone.
struct TodayView: View {
    @Environment(WatchModel.self) private var model
    @State private var capturing = false

    var body: some View {
        let today = model.today()
        NavigationStack {
            List {
                if !model.hasSnapshot {
                    Text("Open GSD on your iPhone to load your tasks.")
                        .foregroundStyle(.secondary)
                } else if !today.picks.isEmpty {
                    Section {
                        ForEach(Array(today.picks.enumerated()), id: \.element.id) { index, task in
                            PickRow(task: task, label: today.rowLabel(at: index))
                        }
                    } header: {
                        Text("Today").accessibilityLabel(today.sectionLabel)
                    }
                } else if today.suggestions.isEmpty {
                    Text("Nothing to pick from yet")
                        .foregroundStyle(.secondary)
                } else {
                    Section("Pick up to three for today") {
                        ForEach(today.suggestions) { task in
                            Button { model.addToToday(task) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(task.title)
                                    Text("Add to today").font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                            .accessibilityLabel("Add \(task.title) to today")
                        }
                    }
                }
            }
            .navigationTitle("Today")
            .toolbar {
                ToolbarItem(placement: .bottomBar) {
                    Button { capturing = true } label: { Label("Add task", systemImage: "plus") }
                }
            }
            .sheet(isPresented: $capturing) { CaptureView() }
        }
    }
}

private struct PickRow: View {
    @Environment(WatchModel.self) private var model
    let task: WatchTask
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(task.title)
            if let due = task.dueDate {
                Text(due.formatted(date: .abbreviated, time: .omitted))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .swipeActions(edge: .leading) {
            Button { model.complete(task) } label: { Label("Complete", systemImage: "checkmark") }
                .tint(.green)
        }
        .swipeActions(edge: .trailing) {
            Button { model.removeFromToday(task) } label: { Label("Remove from today", systemImage: "minus.circle") }
        }
    }
}
