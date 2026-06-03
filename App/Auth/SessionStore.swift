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
    private(set) var lastSync: SyncResult?
    private(set) var syncing = false

    private let auth: AuthService
    private let tokenStore: TokenStore
    private let syncEngine: SyncEngine?
    private let emailKey = "gsd.accountEmail"

    init(auth: AuthService, tokenStore: TokenStore, syncEngine: SyncEngine? = nil) {
        self.auth = auth
        self.tokenStore = tokenStore
        self.syncEngine = syncEngine
        if tokenStore.load() != nil {
            email = UserDefaults.standard.string(forKey: emailKey)
        }
    }

    var isSignedIn: Bool { email != nil || tokenStore.load() != nil }

    func signIn(provider: String) async {
        inProgress = true; lastError = nil
        defer { inProgress = false }
        do {
            let result = try await auth.signIn(provider: provider)
            email = result.record.email
            UserDefaults.standard.set(result.record.email, forKey: emailKey)
            await runSync(trigger: .signIn)   // first sign-in seeds + pulls the user's existing tasks
        } catch AuthError.cancelled {
            // user dismissed — silent, stay signed out, no banner
        } catch {
            lastError = String(localized: "Sign-in failed. Please try again.")
        }
    }

    func signOut() {
        auth.signOut()
        email = nil
        UserDefaults.standard.removeObject(forKey: emailKey)
        _Concurrency.Task { await syncEngine?.resetCursor() }   // re-seed + full-pull next sign-in; local tasks kept
    }

    /// Manual "Sync Now" (Settings). The launch/after-sign-in triggers fire automatically.
    func syncNow() async { await runSync(trigger: .manual) }

    private func runSync(trigger: SyncTrigger) async {
        guard let syncEngine else { return }
        syncing = true; defer { syncing = false }
        lastSync = await syncEngine.sync(trigger: trigger)
    }
}
