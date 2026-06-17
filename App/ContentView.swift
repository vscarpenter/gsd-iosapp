import SwiftUI
import CoreSpotlight
import GSDModel
import GSDStore
import GSDSnapshot

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
    @Environment(TaskStore.self) private var store
    @Environment(SessionStore.self) private var session
    @AppStorage("showCompleted", store: .shared) private var showCompleted = false
    @AppStorage("appTheme", store: .shared) private var themeRaw = AppTheme.system.rawValue

    @State private var palette = PaletteController()
    @State private var paletteEditor: EditorRequest?
    /// Stashed when the palette picks an editor result; acted on in the sheet's onDismiss
    /// so we don't dismiss + present in the same runloop (iOS drops the second present).
    @State private var pendingEditor: EditorRequest?
    /// Mac "About GSD" panel (app menu), posted by GSDMenuCommands on Catalyst.
    @State private var showAbout = false

    var body: some View {
        rootContent
            .environment(palette)
            // Hidden ⌘K trigger — a zero-size button carrying the keyboard shortcut so the
            // hardware ⌘K opens the palette anywhere in the app.
            .background { keyboardShortcuts }
            // Catalyst re-inject: its sheet hosting controller evaluates the presentation's
            // preferences before it inherits the presenter's environment, so @Observable stores
            // must be re-applied on the presented content (a no-op on iOS). Without it, the sheet's
            // @Environment(TaskStore.self) read traps ("No Observable object of type TaskStore").
            .sheet(isPresented: $palette.showPalette, onDismiss: presentPendingEditor) {
                CommandPaletteView(onSelect: handle).environment(store)
            }
            .sheet(item: $paletteEditor) { TaskEditorView(request: $0).environment(store) }
            .sheet(isPresented: $showAbout) { AboutView().presentationSizing(.fitted) }
            .onOpenURL { handleDeepLink($0) }
            .onContinueUserActivity(CSSearchableItemActionType, perform: handleSpotlightActivity)
            .onReceive(NotificationCenter.default.publisher(for: .gsdOpenDeepLink)) { notification in
                guard let url = notification.object as? URL else { return }
                // Delivered live — clear the persisted copy or it replays on the next cold launch.
                DeepLinkHandoff.clearPendingURL()
                handleDeepLink(url)
            }
            .onReceive(NotificationCenter.default.publisher(for: .gsdShowCommandPalette)) { _ in
                palette.showPalette = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .gsdShowAbout)) { _ in
                showAbout = true
            }
            .task {
                if let url = DeepLinkHandoff.consumePendingURL() {
                    handleDeepLink(url)
                }
            }
            // Cross-account guard (design 2026-06-10 Fix C): a DIFFERENT account signed in
            // while this device holds tasks from the previous one — sync is parked until the
            // user chooses. Hosted here so sign-ins from Settings AND Onboarding both surface it.
            .confirmationDialog(
                String(localized: "Different account"),
                isPresented: Binding(
                    get: { session.pendingAccountSwitch != nil },
                    set: { presented in
                        if !presented {
                            // Defer one turn: a button action claims synchronously first, so
                            // this only cancels a no-choice (outside-tap) dismissal.
                            _Concurrency.Task { @MainActor in session.cancelAccountSwitchIfUnresolved() }
                        }
                    }
                ),
                titleVisibility: .visible
            ) {
                Button(String(localized: "Keep my tasks")) { session.resolveAccountSwitch(.merge) }
                Button(String(localized: "Start fresh (erase tasks on this device)"), role: .destructive) {
                    session.resolveAccountSwitch(.fresh)
                }
                Button(String(localized: "Cancel"), role: .cancel) { session.resolveAccountSwitch(.cancel) }
            } message: {
                Text(String(localized: "You signed in as \(session.pendingAccountSwitch?.newEmail ?? String(localized: "a different account")), but this device has tasks from a previous account. Keep them and sync them to this account, or start fresh?"))
            }
    }

    @ViewBuilder private var keyboardShortcuts: some View {
        #if targetEnvironment(macCatalyst)
        // On Mac these shortcuts live in the menu bar (GSDMenuCommands) — avoid double-binding.
        // ⌘F is intentionally not re-provided on Mac (the palette opens with ⌘K); ⌘F is left to
        // the system text-find layer.
        EmptyView()
        #else
        Group {
            Button("", action: { palette.showPalette = true })
                .keyboardShortcut("k", modifiers: .command)
            Button("", action: { palette.showPalette = true })
                .keyboardShortcut("f", modifiers: .command)
            Button("", action: { paletteEditor = .new(.urgentImportant, prefill: nil) })
                .keyboardShortcut("n", modifiers: .command)
            Button("", action: { handleDeepLink(DeepLinkRoute.quadrant(.urgentImportant).url) })
                .keyboardShortcut("1", modifiers: .command)
            Button("", action: { handleDeepLink(DeepLinkRoute.quadrant(.notUrgentImportant).url) })
                .keyboardShortcut("2", modifiers: .command)
            Button("", action: { handleDeepLink(DeepLinkRoute.quadrant(.urgentNotImportant).url) })
                .keyboardShortcut("3", modifiers: .command)
            Button("", action: { handleDeepLink(DeepLinkRoute.quadrant(.notUrgentNotImportant).url) })
                .keyboardShortcut("4", modifiers: .command)
        }
        .opacity(0)
        .accessibilityHidden(true)
        #endif
    }

    private func handleDeepLink(_ url: URL) {
        guard let route = DeepLinkParser.route(from: url) else { return }  // ignores gsd://oauth-callback
        switch route {
        case .focus:
            navigate(to: .matrix)   // the Matrix's Q1 quadrant IS today's focus
        case .capture:
            paletteEditor = .new(.urgentImportant, prefill: nil)
        case .quadrant(let quadrant):
            navigate(to: .matrix)
            palette.focusedQuadrant = quadrant
        case .task(let id):
            openTask(id)
        case .smartView(let id):
            openSmartView(id)
        case .dashboard:
            navigate(to: .dashboard)
        case .settings:
            navigate(to: .settings)
        case .archive:
            navigate(to: .archive)
        }
    }

    /// Resolve a task link by direct repository read: on a cold launch (widget tap,
    /// Spotlight result, pending handoff) the observation snapshot is still empty when
    /// the URL arrives, so a `store.tasks` lookup would silently miss every time.
    private func openTask(_ id: String) {
        _Concurrency.Task { @MainActor in
            if let task = try? await store.fetchTask(id: id) {
                paletteEditor = .edit(task)
            } else {
                navigate(to: .matrix)
            }
        }
    }

    private func handleSpotlightActivity(_ activity: NSUserActivity) {
        guard let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return }
        handleDeepLink(DeepLinkRoute.task(id).url)
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
                SettingsView()
                    .tabItem { Label(String(localized: "Settings"), systemImage: "gearshape") }
                    .tag(3)
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
            case .settings: palette.compactTab = 3
            }
        } else {
            switch dest {
            case .matrix: palette.regularSelection = .matrix
            case .browse: break   // iPad has no Browse tab; the sidebar is always visible
            case .archive: palette.regularSelection = .archive
            case .dashboard: palette.regularSelection = .dashboard
            case .settings: palette.regularSelection = .settings
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
    @Environment(SyncCoordinator.self) private var sync
    @State private var editorTarget: SmartViewEditorTarget?
    @State private var actionFailure: TaskActionFailure?

    var body: some View {
        @Bindable var palette = palette
        NavigationSplitView {
            List(selection: $palette.regularSelection) {
                sidebarNavLabel(String(localized: "Matrix"), "square.grid.2x2", .matrix)
                sidebarNavLabel(String(localized: "Dashboard"), "chart.bar.xaxis", .dashboard)

                Section(String(localized: "Smart Views")) {
                    ForEach(store.pinnedViews) { view in sidebarRow(view) }
                    ForEach(BuiltInSmartViews.all.filter { !store.pinnedSmartViewIds.contains($0.id) }) { view in
                        sidebarRow(view)
                    }
                    ForEach(store.customViews.filter { !store.pinnedSmartViewIds.contains($0.id) }) { view in
                        sidebarRow(view)
                    }
                    Button { editorTarget = .create } label: {
                        Label(String(localized: "New Smart View"), systemImage: "plus")
                    }
                    .tint(Surface.tint)
                }

                Section(String(localized: "Library")) {
                    sidebarNavLabel(String(localized: "Archive"), "archivebox", .archive)
                    sidebarNavLabel(String(localized: "Settings"), "gearshape", .settings)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Surface.surface2)
            .navigationTitle("GSD")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { palette.showPalette = true } label: {
                        Label(String(localized: "Search"), systemImage: "magnifyingglass")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SyncStatusChip(phase: sync.phase, pendingCount: sync.pendingCount,
                                   health: sync.health) { palette.regularSelection = .settings }
                }
            }
            .sheet(item: $editorTarget) { SmartViewEditorView(target: $0).environment(store) }  // Catalyst re-inject (see above)
            .taskActionFailureAlert($actionFailure)
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
            case .settings:
                SettingsView()
            case .matrix, .none:
                MatrixGridView()
            }
        }
    }

    /// A top-level sidebar destination: graphite icon + ink label (de-blued chrome).
    private func sidebarNavLabel(_ title: String, _ icon: String, _ item: RegularItem) -> some View {
        Label {
            Text(title).foregroundStyle(sidebarInk(item, base: Surface.ink))
        } icon: {
            Image(systemName: icon).foregroundStyle(sidebarInk(item, base: Surface.ink2))
        }
        .tag(item)
    }

    /// The row's normal ink, or the on-accent glyph color when it is the selected row over the
    /// opaque Catalyst selection fill. iPad's selection is translucent, so it keeps the graphite ink.
    private func sidebarInk(_ item: RegularItem, base: Color) -> Color {
        #if targetEnvironment(macCatalyst)
        palette.regularSelection == item ? Surface.inkOnAccent : base
        #else
        base
        #endif
    }

    @ViewBuilder private func sidebarRow(_ view: SmartView) -> some View {
        SmartViewRow(view: view, selected: palette.regularSelection == .smartView(view.id))
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
                        deleteSmartView(view)
                    } label: {
                        Label(String(localized: "Delete"), systemImage: "trash")
                    }
                }
            }
    }

    private func deleteSmartView(_ view: SmartView) {
        _Concurrency.Task { @MainActor in
            do {
                try await store.deleteView(id: view.id)
            } catch {
                actionFailure = TaskActionFailure(String(localized: "Couldn’t delete “\(view.name)”: \(error.localizedDescription)"))
            }
        }
    }
}
