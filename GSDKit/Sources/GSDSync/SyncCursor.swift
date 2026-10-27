import Foundation
import GSDWire
import GSDStore   // AppGroupDefaults

/// The pull cursor — the max SERVER-stamped `updated` seen, persisted in PocketBase's space
/// form in App-Group defaults (design 2026-06-10 Fix B: device clocks are irrelevant to pull
/// completeness; LWW still resolves on `client_updated_at`). Client-side it's only parsed back
/// to a `Date` or sent as the server-side filter value (the server does the comparison) — no
/// client code relies on string ordering. `nil` ⇒ never synced (triggers the first-sign-in
/// seed). Cleared on sign-out. A legacy CLIENT-time cursor (`gsd.sync.lastSyncAt`) migrates on
/// read with a 24 h rewind (old client stamps are usually near server time; re-pulls are
/// idempotent via the LWW equal-ms no-op) and is retired on the first advance.
// @unchecked Sendable: the engine (an actor) holds this as a dependency and the App constructs
// it in a different isolation domain (C3). It wraps a thread-safe `UserDefaults` (mirrors the
// `nonisolated(unsafe)` treatment of `AppGroupDefaults.shared`) + immutable keys — safe to send.
public struct SyncCursor: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "gsd.sync.lastServerUpdated"
    private let legacyKey = "gsd.sync.lastSyncAt"
    private let versionKey = "gsd.sync.contractVersion"

    /// The pull contract this build speaks, numbered like the web's `PULL_CURSOR_VERSION` so
    /// the two histories read the same. Bump it when a build is the first to read a newly
    /// synced field: a cursor stamped with an older version, or none, pulls everything once
    /// and merges same-version records, which backfills the field onto rows an older build
    /// pulled and stored without it (docs/2026-10-27-synced-field-backfill.md). 3: `saved_at`.
    static let contractVersion = 3

    // public so the App can construct it (C3) and pass it to the public SyncEngine.init;
    // load/advance/clear stay internal — only the same-module engine calls them.
    public init(defaults: UserDefaults = AppGroupDefaults.shared) { self.defaults = defaults }

    func load() -> String? {
        if let current = defaults.string(forKey: key) { return current }
        guard let legacy = defaults.string(forKey: legacyKey),
              let date = WireDate.parse(legacy) else { return nil }
        return WireDate.formatPocketBase(date.addingTimeInterval(-24 * 60 * 60))
    }

    /// Advance to `maxApplied − 5 s` (server-stamped, so no client-clock clamp; the small
    /// rewind covers same-second write overlap). No-op when `maxApplied` is nil.
    func advance(maxApplied: Date?) {
        guard let maxApplied else { return }
        defaults.set(WireDate.formatPocketBase(maxApplied.addingTimeInterval(-5)), forKey: key)
        defaults.set(Self.contractVersion, forKey: versionKey)
        defaults.removeObject(forKey: legacyKey)
    }

    /// A cursor exists from a build that spoke an older contract. A fresh install has no cursor
    /// and nothing to backfill; its first `advance` stamps the current contract.
    func needsBackfill() -> Bool {
        load() != nil && defaults.integer(forKey: versionKey) < Self.contractVersion
    }

    func markBackfilled() { defaults.set(Self.contractVersion, forKey: versionKey) }

    func clear() {
        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: legacyKey)
        defaults.removeObject(forKey: versionKey)
    }
}
