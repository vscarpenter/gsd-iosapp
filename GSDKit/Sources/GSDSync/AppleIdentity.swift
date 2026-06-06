import Foundation

/// Apple Sign In identity helpers (design §3). Pure — no dependencies. `public` because the App's
/// `SessionStore` reads it to drive the relay-email note.
public enum AppleIdentity {
    /// True when `email` is an Apple "Hide My Email" private relay address
    /// (`…@privaterelay.appleid.com`), case-insensitive. A relay sign-in lands a *separate*
    /// PocketBase account — it does not converge by email with the web app (§8.4).
    public static func isRelayEmail(_ email: String) -> Bool {
        email.lowercased().hasSuffix("@privaterelay.appleid.com")
    }
}
