import SwiftUI
import GSDModel
import GSDStore

/// A searchable picker for adding a dependency. Disables any candidate that would
/// create a cycle (product spec §6.8), with an explanation. Runs the BFS check live.
struct DependencyPickerView: View {
    @Environment(TaskStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// The id of the task being edited and its current dependency ids.
    let editingTaskID: String
    let currentDependencies: [String]
    /// Called with the chosen dependency id.
    let onPick: (String) -> Void

    @State private var query = ""

    private var graph: DependencyGraph { DependencyGraph(tasks: store.tasks) }

    private var candidates: [Task] {
        store.tasks.filter { task in
            task.id != editingTaskID &&
            (query.isEmpty || task.title.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        NavigationStack {
            List(candidates) { task in
                let alreadyDep = currentDependencies.contains(task.id)
                let wouldCycle = graph.wouldCreateCycle(adding: task.id, to: editingTaskID)
                let disabled = alreadyDep || wouldCycle
                Button {
                    onPick(task.id)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(task.title)
                        if disabled {
                            Text(alreadyDep
                                 ? String(localized: "Already a dependency")
                                 : String(localized: "Would create a cycle"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(disabled)
            }
            .searchable(text: $query)
            .navigationTitle(String(localized: "Add Dependency"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
            }
        }
    }
}
