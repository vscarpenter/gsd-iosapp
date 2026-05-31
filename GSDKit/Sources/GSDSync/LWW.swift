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

    private static func ms(_ date: Date) -> Int { Int(date.timeIntervalSince1970 * 1000) }
}
