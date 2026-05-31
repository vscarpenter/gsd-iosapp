import SwiftUI
import GSDModel
import GSDStore

/// Adaptive root. Compact (iPhone): a TabView (Matrix · Browse · Dashboard). Regular (iPad):
/// a NavigationSplitView (sidebar Matrix + Dashboard + Smart Views → detail grid / filtered list).
///
/// Also hosts the ⌘K command palette: a hidden keyboard-shortcut button + the palette
/// sheet + the editor sheet it can open live here, while a shared `PaletteController`
/// (injected into the environment) lets each surface's magnifying-glass toolbar button
/// toggle the same palette and lets the selection handler drive navigation state the
/// surfaces own (tab/sidebar selection, the Browse push path).
struct ContentView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @AppStorage("showCompleted", store: .shared) private var showCompleted = false
    @AppStorage("appTheme", store: .shared) private var themeRaw = AppTheme.system.rawValue

    @State private var palette = PaletteController()
    @State private var paletteEditor: EditorRequest?
    /// Stashed when the palette picks an editor result; acted on in the sheet's onDismiss
    /// so we don't dismiss + present in the same runloop (iOS drops the second present).
    @State private var pendingEditor: EditorRequest?

    var body: some View {
        rootContent
            .environment(palette)
            // Hidden ⌘K trigger — a zero-size button carrying the keyboard shortcut so the
            // hardware ⌘K opens the palette anywhere in the app.
            .background {
                Button("", action: { palette.showPalette = true })
                    .keyboardShortcut("k", modifiers: .command)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
            .sheet(isPresented: $palette.showPalette, onDismiss: presentPendingEditor) {
                CommandPaletteView(onSelect: handle)
            }
            .sheet(item: $paletteEditor) { TaskEditorView(request: $0) }
    }

    @ViewBuilder private var rootContent: some View {
        if sizeClass == .compact {
            TabView(selection: $palette.compactTab) {
                MatrixView()
                    .tabItem { Label(String(localized: "Matrix"), systemImage: "square.grid.2x2") }
                    .tag(0)
                SmartViewListView()
                    .tabItem { Label(String(localized: "Browse"), systemImage: "line.3.horizontal.decrease.circle") }
                    .tag(1)
                DashboardView()
                    .tabItem { Label(String(localized: "Dashboard"), systemImage: "chart.bar.xaxis") }
                    .tag(2)
            }
        } else {
            RegularRootView()
        }
    }

    private func handle(_ result: PaletteResult) {
        switch result {
        case .openTask(let task): pendingEditor = .edit(task)
        case .newTask: pendingEditor = .new(.urgentImportant, prefill: nil)
        case .toggleShowCompleted: showCompleted.toggle()
        case .toggleTheme:
            let order = AppTheme.allCases
            let current = AppTheme(rawValue: themeRaw) ?? .system
            let next = order[(order.firstIndex(of: current).map { $0 + 1 } ?? 0) % order.count]
            themeRaw = next.rawValue
        case .navigate(let dest): navigate(to: dest)
        case .openSmartView(let id): openSmartView(id)
        }
    }

    /// The palette dismissed; if it picked an editor result, present it now (separate runloop).
    private func presentPendingEditor() {
        guard let pending = pendingEditor else { return }
        pendingEditor = nil
        paletteEditor = pending
    }

    private func navigate(to dest: PaletteDestination) {
        if sizeClass == .compact {
            switch dest {
            case .matrix: palette.compactTab = 0
            case .browse: palette.compactTab = 1; palette.browsePath = []
            case .archive: palette.compactTab = 1; palette.browsePath = [.archive]
            case .dashboard: palette.compactTab = 2
            }
        } else {
            switch dest {
            case .matrix: palette.regularSelection = .matrix
            case .browse: break   // iPad has no Browse tab; the sidebar is always visible
            case .archive: palette.regularSelection = .archive
            case .dashboard: palette.regularSelection = .dashboard
            }
        }
    }

    private func openSmartView(_ id: String) {
        if sizeClass == .compact {
            palette.compactTab = 1
            palette.browsePath = [.view(id)]
        } else {
            palette.regularSelection = .smartView(id)
        }
    }
}

/// iPad split view. Sidebar selection drives the detail column.
private struct RegularRootView: View {
    @Environment(TaskStore.self) private var store
    @Environment(PaletteController.self) private var palette
    @State private var editorTarget: SmartViewEditorTarget?

    var body: some View {
        @Bindable var palette = palette
        NavigationSplitView {
            List(selection: $palette.regularSelection) {
                Label(String(localized: "Matrix"), systemImage: "square.grid.2x2").tag(RegularItem.matrix)
                Label(String(localized: "Dashboard"), systemImage: "chart.bar.xaxis").tag(RegularItem.dashboard)
                Label(String(localized: "Archive"), systemImage: "archivebox").tag(RegularItem.archive)
                if !store.pinnedViews.isEmpty {
                    Section(String(localized: "Pinned")) {
                        ForEach(store.pinnedViews) { view in sidebarRow(view) }
                    }
                }
                Section(String(localized: "Built-in")) {
                    ForEach(BuiltInSmartViews.all.filter { !store.pinnedSmartViewIds.contains($0.id) }) { view in
                        sidebarRow(view)
                    }
                }
                Section(String(localized: "Custom")) {
                    ForEach(store.customViews.filter { !store.pinnedSmartViewIds.contains($0.id) }) { view in
                        sidebarRow(view)
                    }
                    Button { editorTarget = .create } label: {
                        Label(String(localized: "New Smart View"), systemImage: "plus")
                    }
                }
            }
            .navigationTitle("GSD")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { palette.showPalette = true } label: {
                        Label(String(localized: "Search"), systemImage: "magnifyingglass")
                    }
                }
            }
            .sheet(item: $editorTarget) { SmartViewEditorView(target: $0) }
        } detail: {
            switch palette.regularSelection {
            case .smartView(let id):
                if let view = store.allViews.first(where: { $0.id == id }) {
                    NavigationStack { FilteredTaskListView(view: view) }
                } else {
                    MatrixGridView()
                }
            case .archive:
                NavigationStack { ArchiveListView() }
            case .dashboard:
                DashboardView()
            case .matrix, .none:
                MatrixGridView()
            }
        }
    }

    @ViewBuilder private func sidebarRow(_ view: SmartView) -> some View {
        SmartViewRow(view: view)
            .tag(RegularItem.smartView(view.id))
            .contextMenu {
                let isPinned = store.pinnedSmartViewIds.contains(view.id)
                Button {
                    if isPinned { store.unpin(view.id) } else { store.pin(view.id) }
                } label: {
                    Label(isPinned ? String(localized: "Unpin") : String(localized: "Pin"),
                          systemImage: isPinned ? "pin.slash" : "pin")
                }
                if !view.isBuiltIn {
                    Button { editorTarget = .edit(view) } label: {
                        Label(String(localized: "Edit"), systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        _Concurrency.Task { try? await store.deleteView(id: view.id) }
                    } label: {
                        Label(String(localized: "Delete"), systemImage: "trash")
                    }
                }
            }
    }
}
