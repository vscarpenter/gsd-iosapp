import SwiftUI

/// Bordered sign-in label for the non-Apple providers (Google, GitHub), matching
/// `AppleSignInButtonLabel`'s geometry (full width, 44pt min height, 8pt continuous
/// corners) so the three providers present with equal weight. Apple's stays the filled
/// black/white lockup its HIG requires — equal size, distinct fill — instead of one
/// heavy branded control between two bare text links (design critique P3, 2026-07-02).
struct ProviderSignInButtonLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 44)
            .foregroundStyle(Surface.ink)
            .background(Surface.surface)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Surface.hairlineStrong, lineWidth: 1)
            )
    }
}
