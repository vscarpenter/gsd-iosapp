import SwiftUI
import UIKit

enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: String(localized: "System")
        case .light: String(localized: "Light")
        case .dark: String(localized: "Dark")
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

extension Font {
    /// Editorial serif display headings (Apple "New York"). Dynamic Type aware.
    static func serif(_ style: Font.TextStyle) -> Font { .system(style, design: .serif) }
}

/// Warm-paper neutral ramp + functional colors — the quiet half of the editorial
/// design language. The four quadrant pigments (`QuadrantStyle.accent`) are the
/// only strong color; everything structural (text, surfaces, borders) lives here.
/// All values are light/dark adaptive via `Color(light:dark:)`. Swap the four
/// neutral hexes for the cool ramp to reflavor the whole app (see design handoff).
enum Surface {
    static let paper          = Color(light: 0xF4F1E9, dark: 0x17150F) // page background
    static let sunken         = Color(light: 0xECE7DC, dark: 0x100E0A) // grouped/inset fills, tracks
    static let surface        = Color(light: 0xFFFFFF, dark: 0x221E17) // raised cards, sheets
    static let surface2       = Color(light: 0xFBF9F3, dark: 0x1B1812) // secondary surface, circular buttons
    static let hairline       = Color(light: 0xE3DDD0, dark: 0x322D24) // separators, card borders
    static let hairlineStrong = Color(light: 0xD8D1C1, dark: 0x423B2F) // stronger borders, unselected toggles/rings
    static let ink            = Color(light: 0x211E1A, dark: 0xF1ECE2) // primary text
    static let ink2           = Color(light: 0x6E6760, dark: 0xA79F92) // secondary text
    static let ink3           = Color(light: 0xA49B8D, dark: 0x6F685B) // tertiary text, quiet icons
    static let inkOnAccent    = Color(light: 0xFFFFFF, dark: 0x17150F) // glyph drawn on a filled accent (e.g. completed check)

    static let success = Color(light: 0x3E7D52, dark: 0x6FB07F) // completion, "completed" series, 100% progress
    static let alert   = Color(light: 0xB23A2E, dark: 0xE0705F) // overdue, delete, destructive
    static let tint    = Color(light: 0x2C6680, dark: 0x6FAACB) // the single interactive tint — genuine actions only
}

/// Continuous ("squircle") corner radii. The design language uses continuous
/// corners everywhere; pair these with `style: .continuous` at call sites.
enum Radius {
    static let tile: CGFloat   = 8   // small tiles
    static let small: CGFloat  = 12  // tiles / compact groups
    static let input: CGFloat  = 16  // text inputs, stat cards
    static let card: CGFloat   = 22  // cards & grouped panels
    static let sheet: CGFloat  = 26  // detented sheets
}

extension Surface {
    /// Warm-tinted ink used for the soft card shadow (black in dark mode).
    static let shadow = Color(light: 0x282116, dark: 0x000000)
}

extension View {
    /// Raised editorial card: surface fill, hairline border, one soft warm shadow,
    /// continuous corners. Borders do the heavy lifting; the shadow stays subtle.
    func surfaceCard(_ radius: CGFloat = Radius.card) -> some View {
        self
            .background(Surface.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Surface.hairline, lineWidth: 1)
            )
            .shadow(color: Surface.shadow.opacity(0.10), radius: 10, x: 0, y: 4)
    }
}

struct BrandedNavigationTitle: View {
    let screen: String

    var body: some View {
        HStack(spacing: 7) {
            Image("LaunchMark")
                .resizable()
                .scaledToFit()
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)

            Text("GSD")
                .font(.headline.weight(.bold))
                .foregroundStyle(Surface.ink)

            Text("-")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Surface.ink3)

            Text(screen)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Surface.ink2)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "GSD - \(screen)"))
    }
}

@MainActor @ToolbarContentBuilder
func brandedNavigationTitle(_ screen: String) -> some ToolbarContent {
    ToolbarItem(placement: .principal) {
        BrandedNavigationTitle(screen: screen)
    }
}

/// One-time UIKit appearance setup so every `navigationTitle` renders in the
/// editorial New York serif and chrome stays ink (not system blue). Called from
/// `GSDApp.init()`. SwiftUI has no native hook to restyle large titles, so the
/// UIKit appearance proxy is the standard path.
enum AppAppearance {
    @MainActor static func configure() {
        let nav = UINavigationBarAppearance()
        nav.configureWithDefaultBackground() // translucent paper-tinted material
        nav.largeTitleTextAttributes = [
            .font: serifFont(.largeTitle, weight: .semibold),
            .foregroundColor: UIColor(Surface.ink),
        ]
        nav.titleTextAttributes = [
            .font: serifFont(.headline, weight: .semibold),
            .foregroundColor: UIColor(Surface.ink),
        ]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav

        let tab = UITabBarAppearance()
        tab.configureWithDefaultBackground()
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab
    }

    /// New York (serif design) variant of a Dynamic-Type text style. `size: 0`
    /// keeps the style's current point size so titles still honor Dynamic Type.
    private static func serifFont(_ style: UIFont.TextStyle, weight: UIFont.Weight) -> UIFont {
        var descriptor = UIFont.preferredFont(forTextStyle: style).fontDescriptor
        if let serif = descriptor.withDesign(.serif) { descriptor = serif }
        descriptor = descriptor.addingAttributes(
            [.traits: [UIFontDescriptor.TraitKey.weight: weight]]
        )
        return UIFont(descriptor: descriptor, size: 0)
    }
}
