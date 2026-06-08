import Foundation
import Observation
import GSDSync

/// App-facing auth state (§8). Wraps `AuthService` for SwiftUI: signed-in/account/in-progress/error.
/// Keeps auth UI-state OUT of the pure `AuthService` (the `TaskStore` `@MainActor @Observable` precedent).
/// The email is cached in `UserDefaults` for an instant offline launch restore; the token lives in the
/// Keychain. Build + MANUAL (the wrapped `AuthService` logic is unit-tested in Group B).
@MainActor
@Observable
final class SessionStore {
    private(set) var email: String?
    private(set) var inProgress = false
    private(set) var lastError: String?
    /// True when the last sign-in returned an Apple "Hide My Email" relay address — gates the
    /// "separate account" hint (design §3). Reset on sign-out.
    private(set) var usingRelayEmail = false

    /// Set when a DIFFERENT account signed in while local tasks exist (design 2026-06-10
    /// Fix C); the ContentView dialog resolves it. Sync stays parked until resolved.
    struct PendingAccountSwitch: Equatable {
        let newOwnerId: String
        let newEmail: String?
    }
    private(set) var pendingAccountSwitch: PendingAccountSwitch?

    enum AccountSwitchResolution { case merge, fresh, cancel }

    private let auth: AuthService
    private let tokenStore: TokenStore
    private let coordinator: SyncCoordinator?
    private let emailKey = "gsd.accountEmail"
    private let lastOwnerKey = "gsd.lastOwnerId"
    private let hasLocalActiveTasks: @MainActor () -> Bool
    private let eraseLocal: @MainActor () async throws -> Void

    init(auth: AuthService, tokenStore: TokenStore, coordinator: SyncCoordinator? = nil,
         hasLocalActiveTasks: @escaping @MainActor () -> Bool = { false },
         eraseLocal: @escaping @MainActor () async throws -> Void = {}) {
        self.auth = auth
        self.tokenStore = tokenStore
        self.coordinator = coordinator
        self.hasLocalActiveTasks = hasLocalActiveTasks
        self.eraseLocal = eraseLocal
        if tokenStore.load() != nil {
            let cached = UserDefaults.standard.string(forKey: emailKey)
            email = cached
            usingRelayEmail = cached.map(AppleIdentity.isRelayEmail) ?? false
            // Backfill the owner baseline for installs that signed in before Fix C shipped —
            // without it, the first account switch after upgrading couldn't be detected.
            if UserDefaults.standard.string(forKey: lastOwnerKey) == nil,
               let id = auth.currentUserId() {
                UserDefaults.standard.set(id, forKey: lastOwnerKey)
            }
        }
    }

    /// Token-presence is the truth, not the cached email: when the server rejects the session
    /// (401 → Keychain cleared mid-session), Settings must offer sign-in again instead of
    /// showing a signed-in account whose syncs silently no-op.
    var isSignedIn: Bool { tokenStore.load() != nil }

    /// Web-redirect OAuth for every provider (`"google"`, `"apple"`, `"github"`). Apple rides the same
    /// path as the rest — its native sheet was retired (Option A: one PocketBase provider, a Services-ID
    /// `client_id`). Silent on cancel, generic banner otherwise. Sets `usingRelayEmail` so an Apple
    /// "Hide My Email" sign-in surfaces the §3 "separate account" hint regardless of provider.
    func signIn(provider: String) async {
        inProgress = true; lastError = nil
        defer { inProgress = false }
        do {
            let result = try await auth.signIn(provider: provider)
            email = result.record.email
            usingRelayEmail = AppleIdentity.isRelayEmail(result.record.email)
            UserDefaults.standard.set(result.record.email, forKey: emailKey)
            routeAfterSignIn(result)   // same/first account → seed+pull; different → dialog (Fix C)
        } catch AuthError.cancelled {
            // user dismissed — silent, stay signed out, no banner
        } catch {
            lastError = String(localized: "Sign-in failed. Please try again.")
        }
    }

    func signOut() {
        auth.signOut()
        email = nil
        usingRelayEmail = false
        pendingAccountSwitch = nil
        UserDefaults.standard.removeObject(forKey: emailKey)
        // lastOwnerKey is deliberately KEPT — remembering the previous owner is what lets the
        // next sign-in detect an account switch (Fix C).
        coordinator?.signedOut()   // tear down + reset cursor; local tasks kept
    }

    // MARK: Account switch (design 2026-06-10 Fix C)

    /// Same/first account → record owner + start sync (today's behavior). Different account
    /// with local tasks → park sync and let the dialog decide.
    private func routeAfterSignIn(_ result: AuthResult) {
        let last = UserDefaults.standard.string(forKey: lastOwnerKey)
        switch AccountSwitch.evaluate(lastOwnerId: last, newOwnerId: result.record.id,
                                      hasLocalActiveTasks: hasLocalActiveTasks()) {
        case .proceed:
            UserDefaults.standard.set(result.record.id, forKey: lastOwnerKey)
            coordinator?.start(trigger: .signIn)
        case .prompt:
            pendingAccountSwitch = PendingAccountSwitch(newOwnerId: result.record.id,
                                                        newEmail: result.record.email)
        }
    }

    /// Synchronous claim (nil-out) so a button action and the dialog's dismiss binding can
    /// never double-resolve; the async work runs after the claim.
    func resolveAccountSwitch(_ resolution: AccountSwitchResolution) {
        guard let pending = pendingAccountSwitch else { return }
        pendingAccountSwitch = nil
        _Concurrency.Task { await self.apply(resolution, pending: pending) }
    }

    /// Outside-tap dismissal: runs one runloop turn AFTER any button action (which claims
    /// synchronously), so it only fires when the dialog was dismissed without a choice.
    func cancelAccountSwitchIfUnresolved() {
        guard pendingAccountSwitch != nil else { return }
        resolveAccountSwitch(.cancel)
    }

    private func apply(_ resolution: AccountSwitchResolution,
                       pending: PendingAccountSwitch) async {
        switch resolution {
        case .merge:
            UserDefaults.standard.set(pending.newOwnerId, forKey: lastOwnerKey)
            coordinator?.start(trigger: .signIn)
        case .fresh:
            do {
                try await eraseLocal()
            } catch {
                lastError = String(localized: "Couldn't clear this device — signed out instead. Please try again.")
                signOut()
                return
            }
            UserDefaults.standard.set(pending.newOwnerId, forKey: lastOwnerKey)
            coordinator?.start(trigger: .signIn)
        case .cancel:
            signOut()   // no half-signed-in limbo (signed-in UI, parked sync)
        }
    }

    /// Manual "Sync Now" (Settings). The launch/after-sign-in triggers fire from the coordinator.
    func syncNow() async { await coordinator?.syncNow() }
}
