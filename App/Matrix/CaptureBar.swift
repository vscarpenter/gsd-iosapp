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
                    Button(String(localized: "Details")) { onDetails(parsed, override) }
                        .font(.caption)
                }
            }
        }
        .padding(.horizontal).padding(.vertical, 8)
        .background(.bar)
    }

    private func submit() {
        let p = CaptureParser.parse(draft)
        guard !p.title.isEmpty else { return }
        let ov = override
        _Concurrency.Task { @MainActor in
            do {
                try await store.add(p, override: ov)
                draft = ""; override = nil; captureError = nil; focused = true
            } catch {
                captureError = String(localized: "Couldn't add — title must be 1–80 characters.")
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
