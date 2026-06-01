import Foundation
import GSDStore   // AppGroupDefaults

/// The pull cursor (`lastSyncAt`), persisted as an ISO-8601 string in App-Group defaults. Compared
/// and filtered as ISO (lexicographic == chronological, given the consistent fractional+Z format).
/// `nil` ⇒ never synced (triggers the first-sign-in seed). Cleared on sign-out. PROBE-VERIFIED.
struct SyncCursor {
    private let defaults: UserDefaults
    private let key = "gsd.sync.lastSyncAt"

    init(defaults: UserDefaults = AppGroupDefaults.shared) { self.defaults = defaults }

    func load() -> String? { defaults.string(forKey: key) }

    /// Advance to `min(maxApplied, now) − 30 s`, formatted ISO. No-op when `maxApplied` is nil.
    func advance(maxApplied: Date?, now: Date) {
        guard let maxApplied else { return }
        let clamped = min(maxApplied, now).addingTimeInterval(-30)
        defaults.set(WireDate.format(clamped), forKey: key)
    }

    func clear() { defaults.removeObject(forKey: key) }
}
