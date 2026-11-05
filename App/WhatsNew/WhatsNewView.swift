import SwiftUI
import GSDModel
import GSDStore

/// What's New: this build's Apple release notes, newest first, grouped New, Improved, Fixed.
/// Pushed from Settings ▸ About, and shown as a sheet (owned by `ContentView`, via
/// `.gsdShowWhatsNew`) from the palette, the Mac Help menu, and the matrix line. Opening it
/// counts as reading it, so the matrix stops offering the line. Reads no `@Observable` env,
/// so — like `HelpView` — it needs no Catalyst re-injection.
struct WhatsNewView: View {
    @AppStorage(AppGroupDefaults.Key.whatsNewLastSeenVersion, store: .shared) private var lastSeen = ""

    private let releases = WhatsNewContent.appleReleases

    var body: some View {
        List {
            if releases.isEmpty {
                Text(String(localized: "No release notes for this version yet."))
                    .foregroundStyle(Surface.ink2)
            }
            ForEach(releases) { release in
                Section {
                    if let headline = release.headline {
                        Text(headline).font(.body.weight(.medium)).foregroundStyle(Surface.ink)
                    }
                    group(String(localized: "New"), release.new)
                    group(String(localized: "Improved"), release.improved)
                    group(String(localized: "Fixed"), release.fixed)
                } header: {
                    HStack(alignment: .firstTextBaseline) {
                        Text(String(localized: "Version \(release.version)"))
                        Spacer()
                        Text(WhatsNewContent.displayDate(release.date))
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Surface.paper)
        .navigationTitle(String(localized: "What's New"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if let current = WhatsNewContent.runningVersion { lastSeen = current }
        }
    }

    @ViewBuilder
    private func group(_ label: String, _ items: [String]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(Surface.ink2)
                    .accessibilityAddTraits(.isHeader)
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: "•").foregroundStyle(Surface.ink3).accessibilityHidden(true)
                        Text(item).foregroundStyle(Surface.ink)
                    }
                    .font(.subheadline)
                }
            }
            .padding(.vertical, 2)
        }
    }
}
