import SwiftUI
import GSDModel
import GSDSnapshot

/// The compose sheet: editable title, quadrant picker (default Eliminate/Q4), comma tags, the
/// captured URL(s) shown read-only, Add / Cancel (spec §4.2). On Add it builds a SharedCapture
/// and calls `save`; a write failure surfaces inline (no container) — the sheet does not dismiss.
struct ShareComposeView: View {
    let urls: [String]
    let save: (SharedCapture) throws -> Void
    let onComplete: () -> Void
    let onCancel: () -> Void

    @State private var title: String
    @State private var quadrant: Quadrant = .notUrgentNotImportant   // default Eliminate/Q4
    @State private var tagsText = ""
    @State private var errorMessage: String?

    init(initialTitle: String, urls: [String],
         save: @escaping (SharedCapture) throws -> Void,
         onComplete: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.urls = urls
        self.save = save
        self.onComplete = onComplete
        self.onCancel = onCancel
        _title = State(initialValue: initialTitle)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "Task")) {
                    TextField(String(localized: "Title"), text: $title, axis: .vertical)
                }
                Section(String(localized: "Quadrant")) {
                    Picker(String(localized: "Quadrant"), selection: $quadrant) {
                        ForEach(Quadrant.allCases, id: \.self) { q in
                            Text(q.title).tag(q)
                        }
                    }
                }
                Section {
                    TextField(String(localized: "comma, separated, tags"), text: $tagsText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    let chips = SharedCaptureBuilder.committedTags(fromField: tagsText)
                    if !chips.isEmpty {
                        FlowLayout(spacing: 6) {
                            ForEach(chips, id: \.self) { tag in
                                Text(tag)
                                    .font(.footnote)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(.quaternary, in: Capsule())
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text(String(localized: "Tags"))
                } footer: {
                    Text(String(localized: "Separate tags with commas"))
                }
                if !urls.isEmpty {
                    Section(String(localized: "Link")) {
                        ForEach(urls, id: \.self) { url in
                            Text(url).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle(String(localized: "Add to GSD"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel"), action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Add"), action: add)
                }
            }
        }
    }

    private func add() {
        let capture = SharedCapture(
            title: title,
            urls: urls,
            urgent: quadrant.isUrgent,
            important: quadrant.isImportant,
            tags: tagsText.split(separator: ",").map(String.init),   // raw; builder normalizes
            capturedAt: Date()
        )
        do {
            try save(capture)
            onComplete()
        } catch {
            errorMessage = String(localized: "Couldn't save to GSD. Please try again.")
        }
    }
}

/// Flows its subviews left-to-right, wrapping to a new row when the next one won't fit — SwiftUI
/// has no built-in wrap layout, and the tag chips can exceed one line (up to 20 tags).
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, rowHeight: CGFloat = 0, totalHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                totalHeight += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: totalHeight + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
