import Foundation

/// Non-alarming, actionable sync health (§7.7). Pure: the coordinator computes the primitives
/// (oldest-pending timestamp, failed count, token expiry, reachability) and this maps them to a
/// single user-facing level + message. Priority order: offline → failed → stale → token → ok.
public struct SyncHealth: Equatable, Sendable {
    public enum Level: Sendable, Equatable { case ok, warning }
    public var level: Level
    public var message: String?
    public init(level: Level, message: String?) { self.level = level; self.message = message }

    public static func evaluate(oldestPendingMs: Int?, failedCount: Int, tokenExpiry: Date?,
                                online: Bool, now: Date,
                                staleThresholdSeconds: TimeInterval = 3600) -> SyncHealth {
        if !online {
            return SyncHealth(level: .warning,
                              message: String(localized: "You're offline — changes will sync when you reconnect."))
        }
        if failedCount > 0 {
            return SyncHealth(level: .warning,
                              message: String(localized: "\(failedCount) changes failed to sync — tap Sync Now to retry."))
        }
        if let oldestPendingMs {
            let ageSeconds = now.timeIntervalSince1970 - Double(oldestPendingMs) / 1000
            if ageSeconds > staleThresholdSeconds {
                return SyncHealth(level: .warning,
                                  message: String(localized: "Some changes haven't synced in a while — tap Sync Now."))
            }
        }
        if let tokenExpiry, tokenExpiry <= now {
            return SyncHealth(level: .warning,
                              message: String(localized: "Your session expired — sign in again to keep syncing."))
        }
        return SyncHealth(level: .ok, message: nil)
    }
}
