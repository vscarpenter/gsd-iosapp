import SwiftUI
import GSDModel
import GSDStore

/// Browse (iPhone tab): pinned views first, then built-ins, then custom — with a "+"
/// to create a custom view and per-custom-row edit/delete/pin actions.
struct SmartViewListView: View {
    @Environment(TaskStore.self) private var store
    @Environment(PaletteController.self) private var palette
    @State private var editorTarget: SmartViewEditorTarget?

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
            .navigationDestination(for: BrowseRoute.self) { route in
                switch route {
                case .view(let id):
                    if let view = store.allViews.first(where: { $0.id == id }) {
                        FilteredTaskListView(view: view)
                    }
                case .archive:
                    ArchiveListView()
                }
            }
            .toolbar {
                paletteButton(palette)
                ToolbarItem(placement: .topBarTrailing) {
                    Button { editorTarget = .create } label: {
                        Label(String(localized: "New Smart View"), systemImage: "plus")
                    }
                }
            }
            .sheet(item: $editorTarget) { SmartViewEditorView(target: $0) }
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
                        _Concurrency.Task { try? await store.deleteView(id: view.id) }
                    } label: { Label(String(localized: "Delete"), systemImage: "trash") }
                        .tint(Surface.alert)
                    Button { editorTarget = .edit(view) } label: {
                        Label(String(localized: "Edit"), systemImage: "pencil")
                    }.tint(Surface.tint)
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
    private var count: Int { store.tasks(matching: view.criteria).count }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: view.icon)
                .font(.body)
                .foregroundStyle(Self.identityColor(for: view.id))
                .frame(width: 28)
            Text(view.name).foregroundStyle(Surface.ink)
            Spacer()
            Text("\(count)").font(.callout).monospacedDigit().foregroundStyle(Surface.ink3)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "\(view.name), \(count) tasks"))
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
