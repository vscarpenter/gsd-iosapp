import AuthenticationServices
import UIKit
import GSDSync

/// Live `WebAuthPresenting` over `ASWebAuthenticationSession` (§8.2). Build + MANUAL — exercised by the
/// live round-trip, never `swift test`. Distinguishes user-cancel (silent) from a presentation failure
/// (surfaced). The session is created/started on the main actor and retained until completion.
final class LiveWebAuthPresenter: NSObject, WebAuthPresenting, @unchecked Sendable {
    private var session: ASWebAuthenticationSession?

    func present(authURL: URL, callbackURLScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            Task { @MainActor in
                let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: callbackURLScheme) { callbackURL, error in
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
                self.session = session
                if !session.start() {
                    continuation.resume(throwing: AuthError.presentationFailed)
                }
            }
        }
    }
}

extension LiveWebAuthPresenter: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.first { $0.activationState == .foregroundActive }?.keyWindow ?? scenes.first?.keyWindow
        return window ?? ASPresentationAnchor()
    }
}
