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
    @State private var selection = Set<String>()
    @State private var actionFailure: TaskActionFailure?
    @Environment(\.editMode) private var editMode

    private var tasks: [Task] {
        var criteria = view.criteria
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { criteria.searchQuery = trimmed }   // overlay search on the view's criteria
        return store.tasks(matching: criteria)
    }
    private var graph: DependencyGraph { DependencyGraph(tasks: store.tasks) }

    /// View-aware empty state (design §10): a reassuring green check for an empty
    /// Overdue view, a trophy for Wins, a search-miss message while searching, else
    /// a generic prompt naming the view.
    @ViewBuilder private var emptyState: some View {
        let searching = !searchText.trimmingCharacters(in: .whitespaces).isEmpty
        if searching {
            EmptyStateView(icon: "magnifyingglass",
                           title: String(localized: "No tasks match \"\(searchText)\""),
                           message: String(localized: "Try a different word, tag, or quadrant."))
        } else if view.id == "overdue" {
            EmptyStateView(icon: "checkmark.circle", iconColor: Surface.success,
                           title: String(localized: "Nothing overdue."),
                           message: String(localized: "You're all caught up."))
        } else if view.id == "weeks-wins" {
            EmptyStateView(icon: "trophy",
                           title: String(localized: "No wins logged yet."),
                           message: String(localized: "Completed tasks from the last 7 days show here."))
        } else {
            EmptyStateView(icon: view.icon,
                           title: String(localized: "Nothing here yet."),
                           message: String(localized: "Tasks matching \"\(view.name)\" will appear here."))
        }
    }

    var body: some View {
        let rowActions = TaskActions(
            store: store,
            onCompleted: { confettiTrigger += 1 },
            onError: { actionFailure = TaskActionFailure($0) }
        )
        ZStack {
            Group {
                if tasks.isEmpty {
                    emptyState
                } else {
                    List(selection: $selection) {
                        ForEach(tasks) { task in
                            TaskListRow(
                                task: task,
                                blockedByCount: graph.uncompletedBlockers(of: task.id).count,
                                blockingCount: graph.blockedTasks(of: task.id).count,
                                actions: rowActions,
                                onEdit: { editor = .edit($0) }
                            )
                            .tag(task.id)
                            .listRowBackground(Surface.surface)
                            .listRowSeparatorTint(Surface.hairline)
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Surface.paper)
            ConfettiView(trigger: confettiTrigger)
        }
        .navigationTitle(view.name)
        .searchable(text: $searchText, prompt: String(localized: "Search \(view.name)"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
        }
        // Hosted via safeAreaInset (not a .bottomBar toolbar item) so the bar's
        // confirmation/alert/sheet present reliably on iPhone + iPad. Mirrors how
        // MatrixView hosts CaptureBar via .safeAreaInset.
        .safeAreaInset(edge: .bottom) {
            if !selection.isEmpty {
                BulkActionBar(selection: $selection)
                    .background(.bar)
            }
        }
        .sheet(item: $editor) { TaskEditorView(request: $0) }
        .taskActionFailureAlert($actionFailure)
        .onChange(of: editMode?.wrappedValue) { _, mode in
            if mode?.isEditing == false { selection.removeAll() }
        }
    }
}
