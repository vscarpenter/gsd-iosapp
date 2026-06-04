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
                let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: callbackURLScheme) { callbackURL, error in
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
        anchor ?? Self.currentPresentationAnchor()!
    }
}
