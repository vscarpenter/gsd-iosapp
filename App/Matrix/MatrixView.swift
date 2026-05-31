import SwiftUI
import GSDModel
import GSDStore

/// iPhone: capture bar + a List of stacked quadrant sections (Q1→Q4).
struct MatrixView: View {
    @Environment(TaskStore.self) private var store
    @Environment(PaletteController.self) private var palette
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
                .toolbar {
                    paletteButton(palette)
                    showCompletedToggle($showCompleted)
                }
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

/// A magnifying-glass toolbar button that opens the ⌘K command palette. Lives in each
/// compact surface's own toolbar (the root TabView has no NavigationStack to host one).
@MainActor @ToolbarContentBuilder
func paletteButton(_ palette: PaletteController) -> some ToolbarContent {
    ToolbarItem(placement: .topBarLeading) {
        Button { palette.showPalette = true } label: {
            Label(String(localized: "Search"), systemImage: "magnifyingglass")
        }
    }
}
