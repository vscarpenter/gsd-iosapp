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
    @Environment(SyncCoordinator.self) private var sync
    @AppStorage("showCompleted", store: .shared) private var showCompleted = false
    @State private var actionFailure: TaskActionFailure?
    @State private var selection = Set<String>()
    @Environment(\.editMode) private var editMode
    var onCompleted: () -> Void

    private let columns = [GridItem(.flexible(), spacing: gridSpacing), GridItem(.flexible(), spacing: gridSpacing)]
    private var isSelecting: Bool { editMode?.wrappedValue.isEditing == true }

    /// Equal 16-point panel rhythm, horizontal and vertical, inside a 12-point inset.
    private static let gridSpacing: CGFloat = 16
    private static let gridInset: CGFloat = 12
    /// Below this much height two content-sized rows do not fit (the iPhone Duo's inner display
    /// in landscape, an iPad mini in landscape), so the grid pins both rows to half the viewport
    /// and each cell scrolls its own list: the whole 2x2 stays in view, which is the matrix's
    /// point. iPad Air and Pro, portrait and landscape, stay above it and keep content-sized
    /// cells with the page scrolling.
    static let pinnedRowsBelowHeight: CGFloat = 760

    /// Half the viewport, less the inset and the gap, or nil when the rows stay content-sized.
    static func pinnedRowHeight(for viewportHeight: CGFloat) -> CGFloat? {
        guard viewportHeight > 0, viewportHeight < pinnedRowsBelowHeight else { return nil }
        return (viewportHeight - 2 * gridInset - gridSpacing) / 2
    }

    var body: some View {
        VStack(spacing: 0) {
            CaptureBar { parsed, ov in
                palette.editor = .new(ov ?? Quadrant(urgent: parsed.urgent, important: parsed.important), prefill: parsed)
            }
            ScrollViewReader { proxy in
                GeometryReader { viewport in
                    let pinnedHeight = Self.pinnedRowHeight(for: viewport.size.height)
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: Self.gridSpacing) {
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
                                    pinnedHeight: pinnedHeight,
                                    onEdit: { palette.editor = .edit($0) },
                                    onAdd: { palette.editor = .new(q, prefill: nil) }
                                )
                                .id(q)
                            }
                        }
                        .padding(Self.gridInset)
                    }
                    .swipeActionsContainerIfAvailable()
                    .refreshable { await sync.syncNow() }
                    .onChange(of: palette.focusedQuadrant) { _, _ in consumeQuadrantFocus(proxy) }
                    .onAppear { consumeQuadrantFocus(proxy) }
                }
            }
        }
        .background(Surface.paper)
        .navigationTitle("Matrix")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarTitleDisplayMode(.inline)
        .brandedNavigationTitle(String(localized: "Matrix"))
        .toolbar {
            showCompletedToggle($showCompleted)
            ToolbarItem(placement: .topBarTrailing) { EditButton() }.overflowsFirst()
        }
        // Bar visual sits in a bottom safeAreaInset; its prompts present from the main
        // content (see BulkActionBar) so they don't get reparented out of existence.
        .bulkActionBar(selection: $selection, failure: $actionFailure)
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

private extension View {
    /// Coordinates the cards' system swipe actions across all four cells: one row open at a
    /// time, and a scroll or an outside tap closes it (List does this on its own; a ScrollView
    /// needs the modifier). iOS 27 only; on the 26 floor the cards use `SwipeRevealRow`, which
    /// coordinates itself through `QuadrantCell.openTaskID`.
    @ViewBuilder func swipeActionsContainerIfAvailable() -> some View {
        if #available(iOS 27, macOS 27, *) {
            swipeActionsContainer()
        } else {
            self
        }
    }
}
