import SwiftUI

/// The hand-rendered "Sign in with Apple" label lockup, shared by `SettingsView` and
/// `OnboardingView` so the two renditions stay pixel-identical (App Review compares this
/// bespoke control against Apple's button spec — one source of truth prevents drift).
///
/// Appearance follows Apple's HIG: the `applelogo` glyph + exact "Sign in with Apple"
/// wording, black-on-light / white-on-dark, 8pt continuous corners, 44pt minimum height.
///
/// Wrap it in a `Button` at the call site — the *action* differs (Settings disables while a
/// sign-in is in progress, Onboarding does not), so only the appearance is shared here.
///
/// Why not `SignInWithAppleButton`? It always triggers the retired native sheet; GSD drives
/// the same web-redirect OAuth flow as Google to satisfy App Review Guideline 4.8, so the
/// button is hand-rendered.
struct AppleSignInButtonLabel: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Label(String(localized: "Sign in with Apple"), systemImage: "applelogo")
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 44)
            .foregroundStyle(colorScheme == .dark ? .black : .white)
            .background(colorScheme == .dark ? Color.white : Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
