import SwiftUI
import GSDModel
import GSDStore

/// Capture field with a live parse preview and a cycling quadrant override.
struct CaptureBar: View {
    @Environment(TaskStore.self) private var store
    @State private var draft = ""
    @State private var override: Quadrant?
    @State private var captureError: String?
    @FocusState private var focused: Bool
    /// Opens the full editor pre-filled from the current parse.
    var onDetails: (ParsedCapture, Quadrant?) -> Void

    private var parsed: ParsedCapture { CaptureParser.parse(draft) }
    private var previewQuadrant: Quadrant {
        override ?? Quadrant(urgent: parsed.urgent, important: parsed.important)
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                TextField(String(localized: "Capture a task…  (try !!  *  #tag)"), text: $draft)
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit(submit)
                    .onChange(of: draft) { _, _ in captureError = nil }
                Button(action: cycleOverride) {
                    Label(previewQuadrant.title, systemImage: QuadrantStyle.symbol(previewQuadrant))
                        .font(.caption)
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(QuadrantStyle.accent(previewQuadrant))
                }
                .buttonStyle(.bordered)
                .accessibilityHint(String(localized: "Cycles the target quadrant"))
            }
            if let captureError {
                Text(captureError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !draft.isEmpty {
                HStack(spacing: 6) {
                    ForEach(parsed.tags, id: \.self) { tag in
                        Text("#\(tag)").font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                    Spacer()
                    Button(String(localized: "Details")) {
                        onDetails(parsed, override)
                        // Consume the capture: the editor now owns this task. Without this, the draft
                        // lingers and a subsequent submit creates a duplicate (title-only) task.
                        draft = ""; override = nil; captureError = nil
                    }
                        .font(.caption)
                }
            }
        }
        .padding(.horizontal).padding(.vertical, 8)
        .background(.bar)
    }

    private func submit() {
        let raw = draft
        let p = CaptureParser.parse(raw)
        guard !p.title.isEmpty else { return }
        let ov = override
        // Consume the draft SYNCHRONOUSLY so the "Details" affordance disappears the instant Done is
        // pressed — otherwise the field stays populated during the async add (incl. the Phase-5c sync
        // enqueue) and a quick "Details" tap creates a SECOND task (title-only from add + details from
        // the editor). Restore the raw text on failure so the user can retry.
        draft = ""; override = nil; captureError = nil
        _Concurrency.Task { @MainActor in
            do {
                try await store.add(p, override: ov)
                focused = true
            } catch let error as ValidationError {
                draft = raw; override = ov; captureError = error.message; focused = true
            } catch {
                draft = raw; override = ov
                captureError = String(localized: "Couldn't add. Please try again.")
                focused = true
            }
        }
    }

    private func cycleOverride() {
        let order: [Quadrant?] = [nil, .urgentImportant, .notUrgentImportant,
                                  .urgentNotImportant, .notUrgentNotImportant]
        let i = order.firstIndex(of: override) ?? 0
        override = order[(i + 1) % order.count]
    }
}
