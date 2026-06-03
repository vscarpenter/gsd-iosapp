import SwiftUI
import GSDSync

/// Quiet toolbar status indicator (§7.7): hidden when idle/healthy; a spinner while syncing;
/// "↻N" when items are pending; an amber warning glyph on error/health-warning. Tapping invokes
/// `onTap` (the host routes to Settings → Account). Respects Reduce Motion (static glyph, no spin).
struct SyncStatusChip: View {
    let phase: SyncCoordinator.Phase
    let pendingCount: Int
    let health: SyncHealth
    let onTap: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Idle + healthy + nothing pending → render nothing (quiet until it matters).
    private var isQuiet: Bool {
        phase == .idle && pendingCount == 0 && health.level == .ok
    }

    var body: some View {
        if !isQuiet {
            Button(action: onTap) {
                label
            }
            .accessibilityLabel(accessibilityText)
        }
    }

    @ViewBuilder private var label: some View {
        switch phase {
        case .syncing:
            if reduceMotion {
                Image(systemName: "arrow.triangle.2.circlepath")
            } else {
                ProgressView().controlSize(.small)
            }
        case .error:
            Image(systemName: "exclamationmark.icloud").foregroundStyle(.orange)
        case .idle:
            if health.level == .warning {
                Image(systemName: "exclamationmark.icloud").foregroundStyle(.orange)
            } else if pendingCount > 0 {
                Label("\(pendingCount)", systemImage: "arrow.triangle.2.circlepath")
                    .labelStyle(.titleAndIcon).font(.footnote)
            }
        }
    }

    private var accessibilityText: String {
        switch phase {
        case .syncing: return String(localized: "Syncing")
        case .error:   return String(localized: "Sync error")
        case .idle:
            if health.level == .warning { return health.message ?? String(localized: "Sync warning") }
            return String(localized: "\(pendingCount) changes pending")
        }
    }
}
