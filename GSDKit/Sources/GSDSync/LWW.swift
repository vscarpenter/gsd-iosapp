import Foundation

/// Last-write-wins resolution keyed on `client_updated_at` (milliseconds) — product spec §7.3.
/// Guards both push and pull. Compares millisecond integers to match the web app exactly, so a
/// sub-millisecond difference that lands in the same bucket is a no-op (never an overwrite).
enum LWW {
    enum Decision: Equatable { case takeRemote, keepLocal, noOp }

    static func resolve(localUpdatedAt local: Date?, remoteClientUpdatedAt remote: Date?) -> Decision {
        guard let remote else { return .noOp }        // unparseable / missing remote timestamp
        guard let local else { return .takeRemote }   // no local task → take remote
        let l = ms(local), r = ms(remote)
        if r > l { return .takeRemote }
        if l > r { return .keepLocal }
        return .noOp                                   // equal ms → don't overwrite
    }

    /// Tolerated forward skew for a client-stamped `client_updated_at`. Matches the web's
    /// `SYNC_CONFIG.MAX_CLIENT_CLOCK_SKEW_MS`. The stamp comes from the writing device's clock,
    /// so a value past this can't be trusted and must not win every comparison from then on.
    private static let maxClockSkewMs = 5 * 60 * 1000

    /// A remote stamp as ingested: anything past the ceiling comes down to it (web
    /// `clampClientTimestamp`). Compare and store this value, or a stored far-future stamp would
    /// beat every later edit from other devices.
    static func capped(_ remote: Date, now: Date) -> Date {
        let ceiling = ceilingMs(now)
        return ms(remote) > ceiling ? Date(timeIntervalSince1970: Double(ceiling) / 1000) : remote
    }

    /// Whether a remote stamp may overrule a queued write or a tombstone (web `isRemoteNewer`,
    /// `isRemoteNewerThanArchive`). A far-future stamp is never newer. Comparing its capped value
    /// here would resurrect tombstones and block the local edit that heals the record.
    static func isRemoteNewer(_ remote: Date, than local: Date, now: Date) -> Bool {
        isRemoteNewer(remote, thanMs: ms(local), now: now)
    }

    /// The same rule against a stamp already in milliseconds, like a queue row's `timestamp`. A round
    /// trip through `Date` can lose a millisecond, which would make an equal stamp read as newer.
    static func isRemoteNewer(_ remote: Date, thanMs localMs: Int, now: Date) -> Bool {
        ms(remote) <= ceilingMs(now) && ms(remote) > localMs
    }

    private static func ceilingMs(_ now: Date) -> Int { ms(now) + maxClockSkewMs }

    private static func ms(_ date: Date) -> Int { Int(date.timeIntervalSince1970 * 1000) }
}
