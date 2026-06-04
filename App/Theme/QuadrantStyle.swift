import SwiftUI
import GSDModel

/// Accent color (light/dark adaptive) + SF Symbol per quadrant.
/// These four pigments are the *only* strong color in the app (the editorial
/// design language) — chrome stays graphite/ink via `Surface`. Values are the
/// refined, harmonized set from the design handoff (rust/tide/ochre/slate).
enum QuadrantStyle {
    static func accent(_ q: Quadrant) -> Color {
        switch q {
        case .urgentImportant:       Color(light: 0xB23A2E, dark: 0xE0705F) // Rust  · Do First
        case .notUrgentImportant:    Color(light: 0x2C6680, dark: 0x6FAACB) // Tide  · Schedule
        case .urgentNotImportant:    Color(light: 0x8A6A22, dark: 0xCFB266) // Ochre · Delegate
        case .notUrgentNotImportant: Color(light: 0x6F685F, dark: 0xA9A096) // Slate · Eliminate
        }
    }

    /// Tinted card-background wash per quadrant — used behind tag chips inside a
    /// card and behind the selected cell of the editor's 2×2 quadrant picker.
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
