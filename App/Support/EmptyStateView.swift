import SwiftUI

/// The shared full-screen empty-state anatomy (design §10): a quiet SF Symbol on a
/// sunken tile, a New York title3 headline, one secondary sentence, and at most one
/// action (in the single tint). The icon is graphite by default; pass `iconColor`
/// only to reassure (e.g. a green check for "nothing overdue").
struct EmptyStateView: View {
    let icon: String
    var iconColor: Color = Surface.ink3
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: Radius.input, style: .continuous).fill(Surface.sunken)
                Image(systemName: icon).font(.system(size: 28)).foregroundStyle(iconColor)
            }
            .frame(width: 60, height: 60)

            Text(title).font(.serif(.title3).weight(.semibold)).foregroundStyle(Surface.ink)
            Text(message).font(.callout).foregroundStyle(Surface.ink2)
                .multilineTextAlignment(.center).frame(maxWidth: 280)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.callout.weight(.semibold)).foregroundStyle(Surface.tint)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(36)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(message)")
    }
}
