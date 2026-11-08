import SwiftUI
import GSDSnapshot

/// The pieces both pages share, so a Complete on Today offers the same Undo as on Do First and
/// both say when the iPhone hasn't got a change yet.
struct WatchUndoBar: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        if model.canUndo {
            Button("Undo") { model.undo() }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Undo complete")
        }
    }
}

/// "2 changes waiting for iPhone" and when the snapshot was last updated.
struct WatchFooter: View {
    @Environment(WatchModel.self) private var model
    let pending: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if pending > 0 {
                Text(pending == 1 ? "1 change waiting for iPhone" : "\(pending) changes waiting for iPhone")
            }
            if model.hasSnapshot {
                Text("Updated \(model.snapshot.generatedAt.formatted(date: .omitted, time: .shortened))")
            }
        }
        .font(.footnote).foregroundStyle(.secondary)
    }
}
