import SwiftUI
import GSDModel
import GSDStore

/// iPhone: capture bar + a List of stacked quadrant sections (Q1→Q4).
struct MatrixView: View {
    @Environment(TaskStore.self) private var store
    @AppStorage("showCompleted", store: .shared) private var showCompleted = false
    @State private var editor: EditorRequest?
    @State private var confettiTrigger = 0

    var body: some View {
        ZStack {
            NavigationStack {
                List {
                    ForEach(Quadrant.allCases, id: \.self) { q in
                        QuadrantSection(
                            quadrant: q, showCompleted: showCompleted,
                            actions: TaskActions(store: store) { confettiTrigger += 1 },
                            onEdit: { editor = .edit($0) },
                            onAdd: { editor = .new(q, prefill: nil) }
                        )
                    }
                }
                .listStyle(.insetGrouped)
                .navigationTitle("Matrix")
                .toolbar { showCompletedToggle($showCompleted) }
                .safeAreaInset(edge: .top) {
                    CaptureBar { parsed, ov in
                        editor = .new(ov ?? Quadrant(urgent: parsed.urgent, important: parsed.important), prefill: parsed)
                    }
                }
            }
            ConfettiView(trigger: confettiTrigger)
        }
        .sheet(item: $editor) { TaskEditorView(request: $0) }
    }
}

@ToolbarContentBuilder
func showCompletedToggle(_ binding: Binding<Bool>) -> some ToolbarContent {
    ToolbarItem(placement: .topBarTrailing) {
        Toggle(isOn: binding) { Label("Show Completed", systemImage: "checkmark.circle") }
            .toggleStyle(.button)
    }
}
