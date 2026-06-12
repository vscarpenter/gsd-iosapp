import SwiftUI
import GSDModel
import GSDStore

/// iPhone: capture bar + a List of stacked quadrant sections (Q1→Q4).
struct MatrixView: View {
    @Environment(TaskStore.self) private var store
    @Environment(PaletteController.self) private var palette
    @Environment(SyncCoordinator.self) private var sync
    @AppStorage("showCompleted", store: .shared) private var showCompleted = false
    @State private var editor: EditorRequest?
    @State private var confettiTrigger = 0
    @State private var actionFailure: TaskActionFailure?

    var body: some View {
        ZStack {
            NavigationStack {
                Group {
                    if store.tasks.isEmpty {
                        EmptyStateView(icon: "square.grid.2x2",
                                       title: String(localized: "Capture your first task"),
                                       message: String(localized: "Type in the field above — try Call my wife !! #family."))
                    } else {
                        List {
                            ForEach(Quadrant.allCases, id: \.self) { q in
                                QuadrantSection(
                                    quadrant: q, showCompleted: showCompleted,
                                    actions: TaskActions(
                                        store: store,
                                        onCompleted: { confettiTrigger += 1 },
                                        onError: { actionFailure = TaskActionFailure($0) }
                                    ),
                                    onEdit: { editor = .edit($0) },
                                    onAdd: { editor = .new(q, prefill: nil) }
                                )
                            }
                        }
                        .listStyle(.insetGrouped)
                        .listSectionSpacing(28)
                        .scrollContentBackground(.hidden)
                        .refreshable { await sync.syncNow() }
                    }
                }
                .background(Surface.paper)
                .navigationTitle("Matrix")
                .toolbar {
                    paletteButton(palette)
                    showCompletedToggle($showCompleted)
                    ToolbarItem(placement: .topBarTrailing) {
                        SyncStatusChip(phase: sync.phase, pendingCount: sync.pendingCount,
                                       health: sync.health) { palette.compactTab = 3 }
                    }
                }
                .safeAreaInset(edge: .top) {
                    CaptureBar { parsed, ov in
                        editor = .new(ov ?? Quadrant(urgent: parsed.urgent, important: parsed.important), prefill: parsed)
                    }
                }
            }
            ConfettiView(trigger: confettiTrigger)
        }
        .sheet(item: $editor) { TaskEditorView(request: $0) }
        .taskActionFailureAlert($actionFailure)
    }
}

@MainActor @ToolbarContentBuilder
func showCompletedToggle(_ binding: Binding<Bool>) -> some ToolbarContent {
    ToolbarItem(placement: .topBarTrailing) {
        Toggle(isOn: binding) { Label("Show Completed", systemImage: "checkmark.circle") }
            .toggleStyle(.button)
    }
}

/// A magnifying-glass toolbar button that opens the ⌘K command palette. Lives in each
/// compact surface's own toolbar (the root TabView has no NavigationStack to host one).
@MainActor @ToolbarContentBuilder
func paletteButton(_ palette: PaletteController) -> some ToolbarContent {
    ToolbarItem(placement: .topBarLeading) {
        Button { palette.showPalette = true } label: {
            Label(String(localized: "Search"), systemImage: "magnifyingglass")
        }
    }
}
