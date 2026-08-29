import Foundation

/// Apple Sign In identity helpers (design §3). Pure — no dependencies. `public` because the App's
/// `SessionStore` reads it to drive the account note.
public enum AppleIdentity {
    /// True when `email` is an Apple "Hide My Email" private relay address
    /// (`…@privaterelay.appleid.com`), case-insensitive. A relay sign-in lands a *separate*
    /// PocketBase account — it does not converge by email with the web app (§8.4).
    public static func isRelayEmail(_ email: String) -> Bool {
        email.lowercased().hasSuffix("@privaterelay.appleid.com")
    }

    /// What to tell the user about which account they just landed on.
    ///
    /// PocketBase treats each OAuth identity as a distinct user, so the provider a person
    /// picks decides which task set they see. Signing in with Apple here and Google on the
    /// web means two accounts and no shared data — and the failure is silent: sync appears
    /// broken rather than pointed at somewhere else.
    public enum AccountNote: Equatable, Sendable {
        /// A private-relay address. Certainly a separate account — the email cannot match
        /// the one the web app knows.
        case relaySeparateAccount
        /// Any other Apple sign-in. May or may not converge, depending on whether the
        /// backend links identities by verified email, so the wording stays conditional.
        case appleMayDiffer
    }

    /// The note for a completed sign-in, or nil when there is nothing worth saying.
    ///
    /// Previously only relay addresses produced a warning, which under-warned badly: a user
    /// who shares their real Apple address still gets a different PocketBase user than their
    /// Google one, and saw no hint at all.
    public static func accountNote(provider: String, email: String?) -> AccountNote? {
        guard provider.lowercased() == "apple" else { return nil }
        if let email, isRelayEmail(email) { return .relaySeparateAccount }
        return .appleMayDiffer
    }
}
