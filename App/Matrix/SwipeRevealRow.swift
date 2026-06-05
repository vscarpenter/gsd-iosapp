import SwiftUI
import GSDModel

/// iPad swipe-to-reveal actions for a matrix card. The iPad matrix is a `LazyVGrid`,
/// not a `List`, so native `.swipeActions` (which is `List`-only) can't be used; this
/// hand-rolls the same affordance while coexisting with the card's existing
/// drag-to-move, long-press menu, and tap-to-edit.
///
/// The reveal buttons are layered **in front of** the card (only while open). The card
/// owns the swipe / `.draggable` / `.contextMenu` / tap gestures; behind the offset
/// card the buttons' taps were swallowed by the card's hit-region. Layering them on
/// top is the fix — confirmed on a physical iPad (2026-06-05).
///
/// - Leading (swipe right): Complete / Uncomplete, with full-swipe-to-complete.
/// - Trailing (swipe left): Snooze (1 hour) + Delete — tap only, no full-swipe.
struct SwipeRevealRow<Menu: View, Content: View>: View {
    let task: Task
    let actions: TaskActions
    let onEdit: (Task) -> Void
    /// Shared with the enclosing cell so opening one row closes any other open row.
    @Binding var openTaskID: String?
    @ViewBuilder let menu: () -> Menu
    @ViewBuilder let content: () -> Content

    @State private var offset: CGFloat = 0
    @State private var rowSize: CGSize = .zero

    private let buttonWidth: CGFloat = 84
    private var leadingReveal: CGFloat { buttonWidth }        // one button
    private var trailingReveal: CGFloat { buttonWidth * 2 }   // Snooze + Delete
    private let fullSwipeFraction: CGFloat = 0.5              // of the row width

    var body: some View {
        // Buttons pin to whichever edge is open; alignment flips at offset 0 (where no
        // button is shown, so it never flickers mid-swipe).
        ZStack(alignment: offset >= 0 ? .leading : .trailing) {
            content()
                .background(Surface.surface)                  // opaque: hides the actions when closed
                .background(sizeReader)                       // non-intrusive size measurement
                .offset(x: offset)
                .contentShape(Rectangle())
                .onTapGesture { offset == 0 ? onEdit(task) : close() }
                .gesture(swipe)                               // custom swipe (coexists with the two below)
                .draggable(task.id)                           // drag-to-move
                .contextMenu { menu() }                       // long-press menu

            // Reveal buttons occupy ONLY the swiped-open strip (never the visible card),
            // so tap-to-close / swipe-back always reach the card's own gestures.
            if offset > 0 {
                revealButton(task.completed ? "arrow.uturn.left" : "checkmark",
                             task.completed ? String(localized: "Uncomplete") : String(localized: "Complete"),
                             Surface.success) {
                    actions.toggle(task); close()
                }
                .frame(width: offset)                         // grows with the swipe so it fills on a full-swipe
            } else if offset < 0 {
                HStack(spacing: 0) {
                    revealButton("moon.zzz", String(localized: "Snooze"),
                                 QuadrantStyle.accent(.notUrgentNotImportant)) {   // slate
                        actions.snooze(task, by: .oneHour); close()
                    }
                    .frame(width: buttonWidth)
                    revealButton("trash", String(localized: "Delete"), Surface.alert, role: .destructive) {
                        actions.delete(task)
                    }
                    .frame(width: buttonWidth)
                }
                .frame(width: trailingReveal)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .onChange(of: openTaskID) { _, id in
            if id != task.id, offset != 0 { close() }        // another row opened — close this one
        }
    }

    private func revealButton(_ system: String, _ label: String, _ color: Color,
                              role: ButtonRole? = nil,
                              action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            VStack(spacing: 3) {
                Image(systemName: system).font(.headline)
                Text(label).font(.caption2).lineLimit(1).minimumScaleFactor(0.7)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: rowSize.height == 0 ? nil : rowSize.height)
            .background(color)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: Swipe gesture

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { v in
                // Directional lock: only claim horizontal-dominant drags so vertical
                // pans reach the parent ScrollView and short taps still reach tap-to-edit.
                guard abs(v.translation.width) > abs(v.translation.height) else { return }
                let t = v.translation.width
                offset = t > 0 ? min(t, rowSize.width) : max(t, -trailingReveal)
            }
            .onEnded { v in
                let t = v.translation.width
                let fullSwipe = rowSize.width > 0 ? rowSize.width * fullSwipeFraction : leadingReveal * 2.5
                withAnimation(.snappy) {
                    if t > fullSwipe {                        // full-swipe → complete immediately
                        offset = 0
                        actions.toggle(task)
                        clearOpen()
                    } else if t > leadingReveal * 0.6 {       // snap open to the Complete button
                        offset = leadingReveal
                        openTaskID = task.id
                    } else if t < -trailingReveal * 0.6 {     // snap open to Snooze + Delete
                        offset = -trailingReveal
                        openTaskID = task.id
                    } else {
                        offset = 0
                        clearOpen()
                    }
                }
            }
    }

    private func close() {
        withAnimation(.snappy) { offset = 0 }
        clearOpen()
    }

    private func clearOpen() {
        if openTaskID == task.id { openTaskID = nil }
    }

    private var sizeReader: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { rowSize = geo.size }
                .onChange(of: geo.size) { _, s in rowSize = s }
        }
    }
}
