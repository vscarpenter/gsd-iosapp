import SwiftUI
import GSDModel
import GSDStore

/// A smart view's results as a flat, cross-quadrant list. Reuses `TaskListRow`; owns its
/// own editor sheet + confetti (mirrors `MatrixView`). Read-only of `store.tasks(matching:)`.
struct FilteredTaskListView: View {
    @Environment(TaskStore.self) private var store
    let view: SmartView

    @State private var editor: EditorRequest?
    @State private var confettiTrigger = 0
    @State private var searchText = ""

    private var tasks: [Task] {
        var criteria = view.criteria
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { criteria.searchQuery = trimmed }   // overlay search on the view's criteria
        return store.tasks(matching: criteria)
    }
    private var graph: DependencyGraph { DependencyGraph(tasks: store.tasks) }

    var body: some View {
        let rowActions = TaskActions(store: store) { confettiTrigger += 1 }
        ZStack {
            Group {
                if tasks.isEmpty {
                    ContentUnavailableView(String(localized: "No tasks match"),
                                           systemImage: view.icon,
                                           description: Text(String(localized: "Tasks matching \"\(view.name)\" will appear here.")))
                } else {
                    List(tasks) { task in
                        TaskListRow(
                            task: task,
                            blockedByCount: graph.uncompletedBlockers(of: task.id).count,
                            blockingCount: graph.blockedTasks(of: task.id).count,
                            actions: rowActions,
                            onEdit: { editor = .edit($0) }
                        )
                    }
                    .listStyle(.insetGrouped)
                }
            }
            ConfettiView(trigger: confettiTrigger)
        }
        .navigationTitle(view.name)
        .searchable(text: $searchText, prompt: String(localized: "Search \(view.name)"))
        .sheet(item: $editor) { TaskEditorView(request: $0) }
    }
}
