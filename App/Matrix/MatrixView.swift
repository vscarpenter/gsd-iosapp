import SwiftUI
import GSDModel
import GSDStore

/// iPhone: capture bar + a List of stacked quadrant sections (Q1→Q4).
struct MatrixView: View {
    @State private var confettiTrigger = 0

    var body: some View {
        ZStack {
            NavigationStack {
                MatrixListContent(onCompleted: { confettiTrigger += 1 })
            }
            ConfettiView(trigger: confettiTrigger)
        }
    }
}

/// The stack's content, split out so `editMode` is read from INSIDE the NavigationStack.
/// `EditButton` toggles the editMode binding scoped to the stack's contents; a read on the
/// view that *creates* the stack observes a different, never-toggled binding — multi-select
/// would never clear on Done (same scoping as FilteredTaskListView/ArchiveListView, which
/// are hosted inside parent-provided stacks).
private struct MatrixListContent: View {
    @Environment(TaskStore.self) private var store
    @Environment(PaletteController.self) private var palette
    @Environment(SyncCoordinator.self) private var sync
    @AppStorage("showCompleted", store: .shared) private var showCompleted = false
    @State private var actionFailure: TaskActionFailure?
    @State private var selection = Set<String>()
    @Environment(\.editMode) private var editMode
    var onCompleted: () -> Void

    var body: some View {
        Group {
            if store.tasks.isEmpty {
                EmptyStateView(icon: "square.grid.2x2",
                               title: String(localized: "Capture your first task"),
                               message: String(localized: "Type in the field above — try Call my wife !! #family."))
            } else {
                ScrollViewReader { proxy in
                    List(selection: $selection) {
                        ForEach(Quadrant.allCases, id: \.self) { q in
                            QuadrantSection(
                                quadrant: q, showCompleted: showCompleted,
                                actions: TaskActions(
                                    store: store,
                                    onCompleted: onCompleted,
                                    onError: { actionFailure = TaskActionFailure($0) }
                                ),
                                onEdit: { palette.editor = .edit($0) },
                                onAdd: { palette.editor = .new(q, prefill: nil) }
                            )
                        }
                    }
                    .listStyle(.insetGrouped)
                    .listSectionSpacing(32)                         // 4-pt grid: between-quadrant rhythm
                    .contentMargins(.top, 12, for: .scrollContent)  // first card clears the pinned capture bar when scrolled
                    .scrollContentBackground(.hidden)
                    .refreshable { await sync.syncNow() }
                    .onChange(of: palette.focusedQuadrant) { _, _ in consumeQuadrantFocus(proxy) }
                    .onAppear { consumeQuadrantFocus(proxy) }
                }
            }
        }
        .background(Surface.paper)
        .navigationTitle("Matrix")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            brandedNavigationTitle(String(localized: "Matrix"))
            paletteButton(palette)
            showCompletedToggle($showCompleted)
            ToolbarItem(placement: .topBarTrailing) { EditButton() }.overflowsFirst()
            syncStatusChip(sync, palette)
        }
        .safeAreaInset(edge: .top) {
            CaptureBar { parsed, ov in
                palette.editor = .new(ov ?? Quadrant(urgent: parsed.urgent, important: parsed.important), prefill: parsed)
            }
        }
        // Bar visual sits in a bottom safeAreaInset; its prompts present from the main
        // content (see BulkActionBar) so they don't get reparented out of existence.
        .bulkActionBar(selection: $selection, failure: $actionFailure)
        .taskActionFailureAlert($actionFailure)
        .onChange(of: editMode?.wrappedValue) { _, mode in
            if mode?.isEditing == false { selection.removeAll() }
        }
    }

    /// ⌘1–⌘4 / `gsd://quadrant/<q>` land here: scroll to the requested section, one-shot.
    private func consumeQuadrantFocus(_ proxy: ScrollViewProxy) {
        guard let q = palette.focusedQuadrant else { return }
        palette.focusedQuadrant = nil
        withAnimation { proxy.scrollTo(q, anchor: .top) }
    }
}

@MainActor @ToolbarContentBuilder
func showCompletedToggle(_ binding: Binding<Bool>) -> some ToolbarContent {
    ToolbarItem(placement: .topBarTrailing) {
        Toggle(isOn: binding) { Label("Show Completed", systemImage: "checkmark.circle") }
            .toggleStyle(.button)
    }
    .overflowsFirst()
}

extension ToolbarContent {
    /// Ranks a toolbar item below the search button and the sync chip: when the toolbar runs
    /// out of room (a narrow resized window, accessibility text sizes), this item moves to the
    /// overflow menu first, so the chrome the capture flow depends on stays in view. The
    /// modifier is iOS 27 and macOS 26.1; on the iOS 26 floor the item keeps the default rank.
    @ToolbarContentBuilder
    func overflowsFirst() -> some ToolbarContent {
        if #available(iOS 27, macOS 26.1, *) {
            visibilityPriority(.low)
        } else {
            self
        }
    }

    /// The counterpart: the item stays visible longest.
    @ToolbarContentBuilder
    func staysVisible() -> some ToolbarContent {
        if #available(iOS 27, macOS 26.1, *) {
            visibilityPriority(.high)
        } else {
            self
        }
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
    .staysVisible()
}

/// The quiet sync-status chip for compact (iPhone) surfaces. Mirrors the iPad sidebar chip
/// onto each iPhone content tab so sync state is visible from the current surface, not just
/// Matrix. Tapping routes to the Settings tab. Hidden when idle/healthy (see SyncStatusChip),
/// so it adds no chrome until sync is active, pending, or errored.
@MainActor @ToolbarContentBuilder
func syncStatusChip(_ sync: SyncCoordinator, _ palette: PaletteController) -> some ToolbarContent {
    ToolbarItem(placement: .topBarTrailing) {
        SyncStatusChip(phase: sync.phase, pendingCount: sync.pendingCount,
                       health: sync.health) { palette.compactTab = 3 }
    }
}
