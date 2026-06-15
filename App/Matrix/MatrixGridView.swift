import SwiftUI
import GSDModel
import GSDStore

/// iPad: capture bar + a true 2×2 grid (Q1 TL → Q4 BR).
struct MatrixGridView: View {
    @State private var confettiTrigger = 0

    var body: some View {
        ZStack {
            NavigationStack {
                MatrixGridContent(onCompleted: { confettiTrigger += 1 })
            }
            ConfettiView(trigger: confettiTrigger)
        }
    }
}

/// The stack's content, split out so `editMode` is read from INSIDE the NavigationStack.
/// `EditButton` toggles the editMode binding scoped to the stack's contents; reading it on
/// the view that *creates* the stack observes a different, never-toggled binding — the Edit
/// button would flip its label and multi-select would never activate.
private struct MatrixGridContent: View {
    @Environment(TaskStore.self) private var store
    @Environment(PaletteController.self) private var palette
    @AppStorage("showCompleted", store: .shared) private var showCompleted = false
    @State private var editor: EditorRequest?
    @State private var actionFailure: TaskActionFailure?
    @State private var selection = Set<String>()
    @Environment(\.editMode) private var editMode
    var onCompleted: () -> Void

    private let columns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]
    private var isSelecting: Bool { editMode?.wrappedValue.isEditing == true }

    var body: some View {
        VStack(spacing: 0) {
            CaptureBar { parsed, ov in
                editor = .new(ov ?? Quadrant(urgent: parsed.urgent, important: parsed.important), prefill: parsed)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {   // equal 16-pt panel rhythm (H + V)
                        ForEach(Quadrant.allCases, id: \.self) { q in
                            QuadrantCell(
                                quadrant: q, showCompleted: showCompleted,
                                actions: TaskActions(
                                    store: store,
                                    onCompleted: onCompleted,
                                    onError: { actionFailure = TaskActionFailure($0) }
                                ),
                                selection: $selection,
                                isSelecting: isSelecting,
                                onEdit: { editor = .edit($0) },
                                onAdd: { editor = .new(q, prefill: nil) }
                            )
                            .id(q)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: palette.focusedQuadrant) { _, _ in consumeQuadrantFocus(proxy) }
                .onAppear { consumeQuadrantFocus(proxy) }
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
        .sheet(item: $editor) { TaskEditorView(request: $0) }
        .taskActionFailureAlert($actionFailure)
        .onChange(of: editMode?.wrappedValue) { _, mode in
            if mode?.isEditing == false { selection.removeAll() }
        }
    }

    /// ⌘1–⌘4 / `gsd://quadrant/<q>` land here: scroll to the requested cell, one-shot.
    private func consumeQuadrantFocus(_ proxy: ScrollViewProxy) {
        guard let q = palette.focusedQuadrant else { return }
        palette.focusedQuadrant = nil
        withAnimation { proxy.scrollTo(q, anchor: .top) }
    }
}
