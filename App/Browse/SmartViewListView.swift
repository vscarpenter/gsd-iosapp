import SwiftUI
import GSDModel
import GSDStore

/// Browse (iPhone tab): the built-in smart views with live counts; tap → filtered list.
struct SmartViewListView: View {
    var body: some View {
        NavigationStack {
            List(BuiltInSmartViews.all) { view in
                NavigationLink(value: view.id) { SmartViewRow(view: view) }
            }
            .navigationTitle(String(localized: "Browse"))
            .navigationDestination(for: String.self) { id in
                if let view = BuiltInSmartViews.all.first(where: { $0.id == id }) {
                    FilteredTaskListView(view: view)
                }
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
