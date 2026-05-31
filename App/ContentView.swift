import SwiftUI
import GSDModel
import GSDStore

/// Adaptive root. Compact (iPhone): a TabView (Matrix · Browse). Regular (iPad): a
/// NavigationSplitView (sidebar Matrix + Smart Views → detail grid / filtered list).
struct ContentView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        if sizeClass == .compact {
            TabView {
                MatrixView()
                    .tabItem { Label(String(localized: "Matrix"), systemImage: "square.grid.2x2") }
                SmartViewListView()
                    .tabItem { Label(String(localized: "Browse"), systemImage: "line.3.horizontal.decrease.circle") }
            }
        } else {
            RegularRootView()
        }
    }
}

/// iPad split view. Sidebar selection drives the detail column.
private struct RegularRootView: View {
    @Environment(TaskStore.self) private var store
    private enum Item: Hashable { case matrix, smartView(String) }
    @State private var selection: Item? = .matrix
    @State private var editorTarget: SmartViewEditorTarget?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label(String(localized: "Matrix"), systemImage: "square.grid.2x2").tag(Item.matrix)
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
            .sheet(item: $editorTarget) { SmartViewEditorView(target: $0) }
        } detail: {
            switch selection {
            case .smartView(let id):
                if let view = store.allViews.first(where: { $0.id == id }) {
                    NavigationStack { FilteredTaskListView(view: view) }
                } else {
                    MatrixGridView()
                }
            case .matrix, .none:
                MatrixGridView()
            }
        }
    }

    @ViewBuilder private func sidebarRow(_ view: SmartView) -> some View {
        SmartViewRow(view: view)
            .tag(Item.smartView(view.id))
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
