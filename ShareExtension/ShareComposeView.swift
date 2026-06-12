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
                Section(String(localized: "Tags")) {
                    TextField(String(localized: "comma, separated, tags"), text: $tagsText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
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
