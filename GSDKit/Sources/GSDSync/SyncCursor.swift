import Foundation
import GSDStore   // AppGroupDefaults

/// The pull cursor (`lastSyncAt`), persisted as an ISO-8601 string in App-Group defaults. Compared
/// and filtered as ISO (lexicographic == chronological, given the consistent fractional+Z format).
/// `nil` ⇒ never synced (triggers the first-sign-in seed). Cleared on sign-out. PROBE-VERIFIED.
// @unchecked Sendable: the engine (an actor) holds this as a dependency and the App constructs it in
// a different isolation domain (C3). It wraps a thread-safe `UserDefaults` (mirrors the
// `nonisolated(unsafe)` treatment of `AppGroupDefaults.shared`) + an immutable key — safe to send.
public struct SyncCursor: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "gsd.sync.lastSyncAt"

    // public so the App can construct it (C3) and pass it to the public SyncEngine.init;
    // load/advance/clear stay internal — only the same-module engine calls them.
    public init(defaults: UserDefaults = AppGroupDefaults.shared) { self.defaults = defaults }

    func load() -> String? { defaults.string(forKey: key) }

    /// Advance to `min(maxApplied, now) − 30 s`, formatted ISO. No-op when `maxApplied` is nil.
    func advance(maxApplied: Date?, now: Date) {
        guard let maxApplied else { return }
        let clamped = min(maxApplied, now).addingTimeInterval(-30)
        defaults.set(WireDate.format(clamped), forKey: key)
    }

    func clear() { defaults.removeObject(forKey: key) }
}
