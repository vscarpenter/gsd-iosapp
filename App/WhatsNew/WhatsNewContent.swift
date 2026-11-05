import Foundation
import GSDModel

/// This build's Apple release notes, read once from the copy of the web repo's
/// `whats-new.json` that GSDModel bundles (spec: gsd-taskmanager `tasks/spec-whats-new.md`).
enum WhatsNewContent {
    /// The running marketing version, e.g. "3.8.0".
    static let runningVersion: String? = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String

    /// Apple releases at or below the running version, newest first.
    static let appleReleases: [WhatsNew.Release] = {
        do {
            return WhatsNew.releases(try WhatsNew.bundledNotes().releases, for: .apple, upTo: runningVersion)
        } catch {
            // The file ships in GSDModel and WhatsNewContentTests decodes it, so this is a
            // packaging bug. Fail loudly in debug; in release, What's New shows its empty state.
            assertionFailure("whats-new.json failed to load: \(error)")
            return []
        }
    }()

    /// A YYYY-MM-DD release date as "November 5, 2026", read in UTC so it never shifts a day.
    static func displayDate(_ isoDate: String) -> String {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withFullDate]
        guard let date = parser.date(from: isoDate) else { return isoDate }
        var style = Date.FormatStyle(date: .long, time: .omitted)
        style.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return date.formatted(style)
    }
}
