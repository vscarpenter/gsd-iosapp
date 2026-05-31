import SwiftUI
import GSDModel
import GSDStore

/// Browse (iPhone tab): pinned views first, then built-ins, then custom — with a "+"
/// to create a custom view and per-custom-row edit/delete/pin actions.
struct SmartViewListView: View {
    @Environment(TaskStore.self) private var store
    @State private var editorTarget: SmartViewEditorTarget?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        ArchiveListView()
                    } label: {
                        Label(String(localized: "Archive"), systemImage: "archivebox")
                    }
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
            .navigationTitle(String(localized: "Browse"))
            .navigationDestination(for: String.self) { id in
                if let view = store.allViews.first(where: { $0.id == id }) {
                    FilteredTaskListView(view: view)
                }
            }
            .toolbar {
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
        NavigationLink(value: view.id) { SmartViewRow(view: view) }
            .swipeActions(edge: .leading) {
                if store.pinnedSmartViewIds.contains(view.id) {
                    Button { store.unpin(view.id) } label: {
                        Label(String(localized: "Unpin"), systemImage: "pin.slash")
                    }.tint(.gray)
                } else {
                    Button { store.pin(view.id) } label: {
                        Label(String(localized: "Pin"), systemImage: "pin")
                    }.tint(.orange)
                }
            }
            .swipeActions(edge: .trailing) {
                if !view.isBuiltIn {
                    Button(role: .destructive) {
                        _Concurrency.Task { try? await store.deleteView(id: view.id) }
                    } label: { Label(String(localized: "Delete"), systemImage: "trash") }
                    Button { editorTarget = .edit(view) } label: {
                        Label(String(localized: "Edit"), systemImage: "pencil")
                    }.tint(.blue)
                }
            }
    }
}

/// A single smart-view row: icon + name + live result count. Reused by the iPad sidebar.
struct SmartViewRow: View {
    @Environment(TaskStore.self) private var store
    let view: SmartView
    private var count: Int { store.tasks(matching: view.criteria).count }

    var body: some View {
        Label {
            HStack {
                Text(view.name)
                Spacer()
                Text("\(count)").foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: view.icon)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "\(view.name), \(count) tasks"))
    }
}
