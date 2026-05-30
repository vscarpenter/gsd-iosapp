import SwiftUI
import GSDModel

/// Accent color (light/dark adaptive) + SF Symbol per quadrant.
/// NOTE: verify these meet WCAG AA against card backgrounds in both appearances
/// during the Group D accessibility pass (§12.3) — adjust hex if a pair fails.
enum QuadrantStyle {
    static func accent(_ q: Quadrant) -> Color {
        switch q {
        case .urgentImportant:       Color(light: 0xB23A2E, dark: 0xE0705F) // rust
        case .notUrgentImportant:    Color(light: 0x2C6E8F, dark: 0x5FA8CC) // ocean
        case .urgentNotImportant:    Color(light: 0x8A6D1F, dark: 0xCBB264) // olive/amber
        case .notUrgentNotImportant: Color(light: 0x636363, dark: 0x9B9B9B) // gray
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
