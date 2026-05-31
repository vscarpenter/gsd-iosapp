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
                        ForEach(store.pinnedViews) { view in
                            SmartViewRow(view: view).tag(Item.smartView(view.id))
                        }
                    }
                }
                Section(String(localized: "Built-in")) {
                    ForEach(BuiltInSmartViews.all.filter { !store.pinnedSmartViewIds.contains($0.id) }) { view in
                        SmartViewRow(view: view).tag(Item.smartView(view.id))
                    }
                }
                Section(String(localized: "Custom")) {
                    ForEach(store.customViews.filter { !store.pinnedSmartViewIds.contains($0.id) }) { view in
                        SmartViewRow(view: view).tag(Item.smartView(view.id))
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
}
