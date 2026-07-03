import AuthenticationServices
import UIKit
import GSDSync

/// Live `WebAuthPresenting` over `ASWebAuthenticationSession` (§8.2). Build + MANUAL — exercised by the
/// live round-trip, never `swift test`. Distinguishes user-cancel (silent) from a presentation failure
/// (surfaced). The session is created/started on the main actor and retained until completion.
final class LiveWebAuthPresenter: NSObject, WebAuthPresenting, @unchecked Sendable {
    private var session: ASWebAuthenticationSession?
    private var anchor: ASPresentationAnchor?

    func present(authURL: URL, callbackURLScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            Task { @MainActor in
                guard let anchor = Self.currentPresentationAnchor() else {
                    continuation.resume(throwing: AuthError.presentationFailed)
                    return
                }
                // `@Sendable` is load-bearing: under Mac Catalyst, AuthenticationServices invokes this
                // completion on a background XPC queue (com.apple.NSXPCConnection…SafariLaunchAgent), not
                // the main thread as on iOS. Without it, the closure inherits @MainActor from the enclosing
                // Task and the synthesized isolation check trips dispatch_assert_queue(main) → crash. The
                // body is thread-agnostic: a Sendable continuation plus an explicit @MainActor hop below.
                let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: callbackURLScheme) { @Sendable callbackURL, error in
                    Task { @MainActor in
                        self.session = nil
                        self.anchor = nil
                    }
                    if let callbackURL {
                        continuation.resume(returning: callbackURL)
                    } else if let error, case ASWebAuthenticationSessionError.canceledLogin = error {
                        continuation.resume(throwing: AuthError.cancelled)
                    } else {
                        continuation.resume(throwing: AuthError.presentationFailed)
                    }
                }
                session.presentationContextProvider = self
                session.prefersEphemeralWebBrowserSession = false
                self.anchor = anchor
                self.session = session
                if !session.start() {
                    self.session = nil
                    self.anchor = nil
                    continuation.resume(throwing: AuthError.presentationFailed)
                }
            }
        }
    }

    @MainActor
    private static func currentPresentationAnchor() -> ASPresentationAnchor? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let window = scenes.first(where: { $0.activationState == .foregroundActive })?.keyWindow ?? scenes.first?.keyWindow {
            return window
        }
        return scenes.first.map(ASPresentationAnchor.init(windowScene:))
    }
}

extension LiveWebAuthPresenter: ASWebAuthenticationPresentationContextProviding {
    @MainActor
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        if let anchor { return anchor }
        if let current = Self.currentPresentationAnchor() { return current }
        // `present(...)` refuses to start without an anchor, and `anchor` is retained until the
        // completion handler runs. Reaching this means AuthenticationServices asked for an anchor
        // outside an active presentation session.
        preconditionFailure("Missing ASWebAuthenticationSession presentation anchor")
    }
}
