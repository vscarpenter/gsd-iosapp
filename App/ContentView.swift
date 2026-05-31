import SwiftUI
import GSDModel

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
    private enum Item: Hashable { case matrix, smartView(String) }
    @State private var selection: Item? = .matrix

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label(String(localized: "Matrix"), systemImage: "square.grid.2x2").tag(Item.matrix)
                Section(String(localized: "Smart Views")) {
                    ForEach(BuiltInSmartViews.all) { view in
                        SmartViewRow(view: view).tag(Item.smartView(view.id))
                    }
                }
            }
            .navigationTitle("GSD")
        } detail: {
            switch selection {
            case .smartView(let id):
                if let view = BuiltInSmartViews.all.first(where: { $0.id == id }) {
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
