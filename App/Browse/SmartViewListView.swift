import SwiftUI
import GSDModel
import GSDStore

/// Browse (iPhone tab): pinned views first, then built-ins, then custom — with a "+"
/// to create a custom view and per-custom-row edit/delete/pin actions.
struct SmartViewListView: View {
    @Environment(TaskStore.self) private var store
    @Environment(PaletteController.self) private var palette
    @Environment(SyncCoordinator.self) private var sync
    @State private var editorTarget: SmartViewEditorTarget?
    @State private var actionFailure: TaskActionFailure?

    var body: some View {
        @Bindable var palette = palette
        // Browse owns its NavigationStack path so the command palette can push a smart
        // view or Archive into it (value-based links — a BrowseRoute carries both).
        NavigationStack(path: $palette.browsePath) {
            List {
                Section {
                    NavigationLink(value: BrowseRoute.archive) {
                        Label {
                            Text(String(localized: "Archive")).foregroundStyle(Surface.ink)
                        } icon: {
                            Image(systemName: "archivebox").foregroundStyle(Surface.ink2)
                        }
                    }
                    .listRowBackground(Surface.surface)
                }
                if !store.pinnedViews.isEmpty {
                    Section(String(localized: "Pinned")) {
                        ForEach(store.pinnedViews) { view in viewLink(view) }
                    }
                }
                Section(String(localized: "Built-in")) {
                    ForEach(BuiltInSmartViews.all.filter { !store.pinnedSmartViewIds.contains($0.id) }) { view in
                        viewLink(view)
                    }
                }
                if !customRows.isEmpty {
                    Section(String(localized: "Custom")) {
                        ForEach(customRows) { view in viewLink(view) }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Surface.paper)
            .navigationTitle(String(localized: "Browse"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarTitleDisplayMode(.inline)
            .navigationDestination(for: BrowseRoute.self) { route in
                switch route {
                case .view(let id):
                    if let view = store.allViews.first(where: { $0.id == id }) {
                        FilteredTaskListView(view: view)
                    } else {
                        // A stale deep link (e.g. a deleted custom view) used to push a blank
                        // screen here. Show an explicit message instead. A valid-but-not-yet-loaded
                        // view self-heals when the smart-view observer fires (allViews is observed).
                        ContentUnavailableView(
                            String(localized: "Smart view unavailable"),
                            systemImage: "tray",
                            description: Text(String(localized: "This smart view no longer exists. It may have been deleted."))
                        )
                        .background(Surface.paper)
                    }
                case .archive:
                    ArchiveListView()
                }
            }
            .toolbar {
                brandedNavigationTitle(String(localized: "Browse"))
                paletteButton(palette)
                syncStatusChip(sync, palette)
                ToolbarItem(placement: .topBarTrailing) {
                    Button { editorTarget = .create } label: {
                        Label(String(localized: "New Smart View"), systemImage: "plus")
                    }
                }
            }
            .sheet(item: $editorTarget) { SmartViewEditorView(target: $0).environment(store) }  // Catalyst: re-inject store across the sheet boundary
            .taskActionFailureAlert($actionFailure)
        }
    }

    /// Custom views not already shown in the Pinned section.
    private var customRows: [SmartView] {
        store.customViews.filter { !store.pinnedSmartViewIds.contains($0.id) }
    }

    @ViewBuilder private func viewLink(_ view: SmartView) -> some View {
        NavigationLink(value: BrowseRoute.view(view.id)) { SmartViewRow(view: view) }
            .listRowBackground(Surface.surface)
            .swipeActions(edge: .leading) {
                if store.pinnedSmartViewIds.contains(view.id) {
                    Button { store.unpin(view.id) } label: {
                        Label(String(localized: "Unpin"), systemImage: "pin.slash")
                    }.tint(QuadrantStyle.accent(.notUrgentNotImportant)) // slate
                } else {
                    Button { store.pin(view.id) } label: {
                        Label(String(localized: "Pin"), systemImage: "pin")
                    }.tint(Surface.tint)
                }
            }
            .swipeActions(edge: .trailing) {
                if !view.isBuiltIn {
                    Button(role: .destructive) {
                        deleteSmartView(view)
                    } label: { Label(String(localized: "Delete"), systemImage: "trash") }
                        .tint(Surface.alert)
                    Button { editorTarget = .edit(view) } label: {
                        Label(String(localized: "Edit"), systemImage: "pencil")
                    }.tint(Surface.tint)
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

/// A single smart-view row: icon + name + live result count. Reused by the iPad sidebar.
/// Icons are graphite by default and tinted with an accent only for views that
/// carry identity — the key "de-blue" of the Browse surface (design §4).
struct SmartViewRow: View {
    @Environment(TaskStore.self) private var store
    let view: SmartView
    /// When this is the selected sidebar row on Catalyst, the content sits on the opaque accent
    /// fill, so its colors flip to the on-accent glyph color. Default false (the Browse list and
    /// iPad's translucent selection) keeps the identity/ink colors.
    var selected: Bool = false
    private var count: Int { store.tasks(matching: view.criteria).count }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: view.icon)
                .font(.body)
                .foregroundStyle(onAccent(or: Self.identityColor(for: view.id)))
                .frame(width: 28)
            Text(view.name).foregroundStyle(onAccent(or: Surface.ink))
            Spacer()
            Text("\(count)").font(.callout).monospacedDigit()
                .foregroundStyle(onAccent(or: Surface.ink2))   // sidebar rows sit on paper, where ink3 is below AA
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "\(view.name), \(count) tasks"))
    }

    /// `Surface.inkOnAccent` when selected over the opaque Catalyst fill; otherwise `base`.
    private func onAccent(or base: Color) -> Color {
        #if targetEnvironment(macCatalyst)
        selected ? Surface.inkOnAccent : base
        #else
        base
        #endif
    }

    /// Graphite by default; an accent only where the view has identity.
    static func identityColor(for id: String) -> Color {
        switch id {
        case "today-focus":                 QuadrantStyle.accent(.urgentImportant)       // q1
        case "this-week", "ready-to-work":  QuadrantStyle.accent(.notUrgentImportant)    // q2 tide
        case "overdue":                     Surface.alert
        case "weeks-wins":                  QuadrantStyle.accent(.urgentNotImportant)     // q3 ochre
        default:                            Surface.ink2                                  // graphite
        }
    }
}
