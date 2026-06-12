import SwiftUI
import GSDModel
import GSDStore

/// iPad: capture bar + a true 2×2 grid (Q1 TL → Q4 BR).
struct MatrixGridView: View {
    @Environment(TaskStore.self) private var store
    @AppStorage("showCompleted", store: .shared) private var showCompleted = false
    @State private var editor: EditorRequest?
    @State private var confettiTrigger = 0
    @State private var actionFailure: TaskActionFailure?
    @State private var selection = Set<String>()
    @Environment(\.editMode) private var editMode

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
    private var isSelecting: Bool { editMode?.wrappedValue.isEditing == true }

    var body: some View {
        ZStack {
            NavigationStack {
                VStack(spacing: 0) {
                    CaptureBar { parsed, ov in
                        editor = .new(ov ?? Quadrant(urgent: parsed.urgent, important: parsed.important), prefill: parsed)
                    }
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(Quadrant.allCases, id: \.self) { q in
                                QuadrantCell(
                                    quadrant: q, showCompleted: showCompleted,
                                    actions: TaskActions(
                                        store: store,
                                        onCompleted: { confettiTrigger += 1 },
                                        onError: { actionFailure = TaskActionFailure($0) }
                                    ),
                                    selection: $selection,
                                    isSelecting: isSelecting,
                                    onEdit: { editor = .edit($0) },
                                    onAdd: { editor = .new(q, prefill: nil) }
                                )
                            }
                        }
                        .padding(12)
                    }
                }
                .background(Surface.paper)
                .navigationTitle("Matrix")
                .toolbar {
                    showCompletedToggle($showCompleted)
                    ToolbarItem(placement: .topBarTrailing) { EditButton() }
                }
                .safeAreaInset(edge: .bottom) {
                    if !selection.isEmpty {
                        BulkActionBar(selection: $selection)
                            .background(.bar)
                    }
                }
            }
            ConfettiView(trigger: confettiTrigger)
        }
        .sheet(item: $editor) { TaskEditorView(request: $0) }
        .taskActionFailureAlert($actionFailure)
        .onChange(of: editMode?.wrappedValue) { _, mode in
            if mode?.isEditing == false { selection.removeAll() }
        }
    }
}
