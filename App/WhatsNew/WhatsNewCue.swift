import SwiftUI
import GSDModel
import GSDStore

/// One line under the capture bar after a notable update, and nothing else: no alert, modal,
/// or badge (PRODUCT.md — never nag). The rule is `WhatsNew.decide`, pinned by the shared
/// corpus. "See what's new", Dismiss, or opening What's New records the running version on
/// this device. A device with no tasks is a first run: it records the running version and
/// never sees the line (new users get onboarding instead).
struct WhatsNewCue: View {
    @Environment(TaskStore.self) private var store
    @AppStorage(AppGroupDefaults.Key.whatsNewLastSeenVersion, store: .shared) private var lastSeen = ""

    private struct Evaluation {
        var release: WhatsNew.Release?
        var recordVersion: String?
    }

    private var evaluation: Evaluation {
        guard store.hasLoadedTasks, let current = WhatsNewContent.runningVersion else { return Evaluation() }
        let releases = WhatsNewContent.appleReleases
        let decision = WhatsNew.decide(
            releases: releases.map { WhatsNew.Entry(version: $0.version, notable: $0.notable) },
            currentVersion: current,
            lastSeenVersion: lastSeen.isEmpty ? nil : lastSeen,
            existingUser: !store.tasks.isEmpty
        )
        let release = decision.show ? releases.first { $0.version == decision.headlineVersion } : nil
        return Evaluation(release: release, recordVersion: decision.recordVersion)
    }

    var body: some View {
        let evaluation = evaluation
        VStack(spacing: 0) {
            if let release = evaluation.release, let headline = release.headline {
                line(version: release.version, headline: headline)
            }
        }
        .task(id: evaluation.recordVersion) {
            if let version = evaluation.recordVersion { lastSeen = version }
        }
    }

    private func line(version: String, headline: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(Text(String(localized: "New in \(version):")).fontWeight(.semibold).foregroundStyle(Surface.ink)) \(headline)")
                .foregroundStyle(Surface.ink2)
            HStack(spacing: 16) {
                Button(String(localized: "See what's new")) {
                    markSeen()
                    NotificationCenter.default.post(name: .gsdShowWhatsNew, object: nil)
                }
                .foregroundStyle(Surface.tint)
                Button(String(localized: "Dismiss")) { markSeen() }
                    .foregroundStyle(Surface.ink2)
                    .accessibilityLabel(String(localized: "Dismiss what's new"))
            }
            .buttonStyle(.plain)
            .underline()
        }
        .font(.footnote)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Surface.paper)
        .accessibilityElement(children: .contain)
    }

    private func markSeen() {
        if let current = WhatsNewContent.runningVersion { lastSeen = current }
    }
}
