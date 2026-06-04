import SwiftUI
import GSDSync
import GSDStore

/// Sync History screen (§7.7): recent attempts + summary stats. Pushed from Settings → Account.
/// Reads through the engine (the single sync API surface).
struct SyncHistoryView: View {
    let engine: SyncEngine

    @State private var entries: [SyncHistoryEntry] = []
    @State private var stats = SyncHistoryStats()

    var body: some View {
        List {
            Section {
                LabeledContent(String(localized: "Total syncs"), value: "\(stats.totalSyncs)")
                LabeledContent(String(localized: "Successful"), value: "\(stats.successes)")
                LabeledContent(String(localized: "Pushed"), value: "\(stats.totalPushed)")
                LabeledContent(String(localized: "Pulled"), value: "\(stats.totalPulled)")
            }
            Section(String(localized: "Recent")) {
                if entries.isEmpty {
                    Text(String(localized: "No sync history yet.")).foregroundStyle(Surface.ink2)
                }
                ForEach(entries) { entry in row(entry) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Surface.paper)
        .navigationTitle(String(localized: "Sync History"))
        .task { await load() }
        .refreshable { await load() }
    }

    @ViewBuilder private func row(_ e: SyncHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: icon(e.status)).foregroundStyle(color(e.status))
                Text(title(e.status)).font(.subheadline.weight(.medium))
                Spacer()
                Text(date(e.timestamp)).font(.caption).foregroundStyle(Surface.ink3)
            }
            Text(detail(e)).font(.caption).foregroundStyle(Surface.ink3)
        }
        .padding(.vertical, 2)
    }

    private func detail(_ e: SyncHistoryEntry) -> String {
        var parts = [e.triggeredBy == .user ? String(localized: "Manual") : String(localized: "Auto"),
                     "↑\(e.pushedCount)", "↓\(e.pulledCount)"]
        if e.conflictsResolved > 0 { parts.append("⚖\(e.conflictsResolved)") }
        if let f = e.failedCount, f > 0 { parts.append("⚠\(f)") }
        if let d = e.duration { parts.append("\(d) ms") }
        if let m = e.errorMessage { parts.append(m) }
        return parts.joined(separator: " · ")
    }

    private func icon(_ s: SyncHistoryEntry.Status) -> String {
        switch s {
        case .success:  "checkmark.circle.fill"
        case .conflict: "arrow.triangle.2.circlepath"
        case .partial:  "exclamationmark.triangle.fill"
        case .error:    "xmark.circle.fill"
        }
    }
    private func color(_ s: SyncHistoryEntry.Status) -> Color {
        switch s {
        case .success:  Surface.success
        case .conflict: Surface.tint
        case .partial:  QuadrantStyle.accent(.urgentNotImportant) // ochre
        case .error:    Surface.alert
        }
    }
    private func title(_ s: SyncHistoryEntry.Status) -> String {
        switch s {
        case .success:  String(localized: "Success")
        case .conflict: String(localized: "Resolved conflicts")
        case .partial:  String(localized: "Partial")
        case .error:    String(localized: "Error")
        }
    }
    private func date(_ ms: Int) -> String {
        let d = Date(timeIntervalSince1970: Double(ms) / 1000)
        return d.formatted(date: .abbreviated, time: .shortened)
    }

    private func load() async {
        entries = await engine.recentHistory(limit: 50)
        stats = await engine.historyStats()
    }
}
