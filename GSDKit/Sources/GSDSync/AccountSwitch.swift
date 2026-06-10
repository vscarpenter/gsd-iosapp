import Foundation

/// Pure decision for the cross-account guard (design 2026-06-10 Fix C): the §7.4 first-sync
/// seed would silently upload the PREVIOUS account's local tasks into a DIFFERENT account —
/// that needs explicit user consent. `public` — the App's SessionStore routes on it.
public enum AccountSwitch {
    public enum Decision: Equatable, Sendable { case proceed, prompt }

    /// `.prompt` only when a previous owner is known, the new owner differs, and there are
    /// local active tasks to leak. First-ever sign-in (no recorded owner) and same-account
    /// re-auth keep today's behavior. Archived tasks never sync, so they don't gate this.
    public static func evaluate(lastOwnerId: String?, newOwnerId: String,
                                hasLocalActiveTasks: Bool) -> Decision {
        guard let lastOwnerId, lastOwnerId != newOwnerId, hasLocalActiveTasks else { return .proceed }
        return .prompt
    }
}
