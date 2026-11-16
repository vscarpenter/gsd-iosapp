import SwiftUI
import GSDModel

/// Accent color (light/dark adaptive) + SF Symbol per quadrant.
/// These four pigments are the *only* strong color in the app (the editorial
/// design language) — chrome stays graphite/ink via `Surface`. Values are the
/// refined, harmonized set from the design handoff (rust/tide/ochre/slate).
///
/// Contrast, verified 2026-11-16 (docs/2026-11-16-matrix-header-band.md). As text on a white
/// card all four accents pass WCAG AA: tide 6.3:1, rust 5.9:1, slate 5.5:1, ochre 5.0:1. The
/// quadrant headings sit on their `wash` band, where they measure tide 5.3:1, rust 4.8:1,
/// slate 4.5:1, and ochre 4.2:1 in light, and 4.7:1 or better in dark. That passes AA for the
/// large `serif(.title3)` heading, and ochre no longer clears AAA-large. None reach AAA (7:1)
/// as small colored text, an accepted trade for the rationed palette. Tags don't use these
/// colors: a tag chip is `ink2` on `sunken`.
enum QuadrantStyle {
    static func accent(_ q: Quadrant) -> Color {
        switch q {
        case .urgentImportant:       Color(light: 0xB23A2E, dark: 0xE0705F) // Rust  · Do First
        case .notUrgentImportant:    Color(light: 0x2C6680, dark: 0x6FAACB) // Tide  · Schedule
        case .urgentNotImportant:    Color(light: 0x8A6A22, dark: 0xCFB266) // Ochre · Delegate
        case .notUrgentNotImportant: Color(light: 0x6F685F, dark: 0xA9A096) // Slate · Eliminate
        }
    }

    /// The quadrant's tint. It fills the header band of a quadrant's pane and the selected cell
    /// of the editor's 2×2 quadrant picker. Accent text at body size can fall under AA on it
    /// (ochre is 4.2:1), so small text on a tint takes `ink` or `ink2`.
    static func wash(_ q: Quadrant) -> Color {
        switch q {
        case .urgentImportant:       Color(light: 0xF4E4E0, dark: 0x3A211D)
        case .notUrgentImportant:    Color(light: 0xE1ECF1, dark: 0x173039)
        case .urgentNotImportant:    Color(light: 0xF0E9D8, dark: 0x322B17)
        case .notUrgentNotImportant: Color(light: 0xECE9E3, dark: 0x2A2620)
        }
    }

    static func symbol(_ q: Quadrant) -> String {
        switch q {
        case .urgentImportant: "flame.fill"
        case .notUrgentImportant: "calendar"
        case .urgentNotImportant: "person.2.fill"
        case .notUrgentNotImportant: "trash"
        }
    }
}

extension Color {
    /// Light/dark adaptive color from two 0xRRGGBB values.
    init(light: UInt, dark: UInt) {
        self = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }
}

private extension UIColor {
    convenience init(hex: UInt) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
