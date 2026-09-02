import SwiftUI

/// A short state label on a wash capsule — the tag-chip anatomy from `TaskCardView`,
/// reused for status. Two styles, not five: color is rationed, so only overdue earns
/// the alert pigment; everything else is secondary ink on the sunken fill (4.5:1 light,
/// 7.4:1 dark). Adapted from ShipSwift's `SWStatusBadge` (MIT — THIRD_PARTY_NOTICES.md),
/// retinted from system blue/green/orange/red onto `Surface` tokens.
struct StatusBadge: View {
    enum Style {
        case alert, neutral

        var ink: Color {
            switch self {
            case .alert:   Surface.alert
            case .neutral: Surface.ink2
            }
        }
        var wash: Color {
            switch self {
            case .alert:   Surface.alertWash
            case .neutral: Surface.sunken
            }
        }
    }

    let text: String
    let style: Style

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .lineLimit(1).fixedSize()
            .foregroundStyle(style.ink)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(style.wash, in: Capsule())
    }
}
