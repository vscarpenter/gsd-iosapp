import Foundation

/// How the iPad and Mac matrix lays out each quadrant's cards (docs/2026-11-05-matrix-adaptive-columns.md,
/// docs/2026-11-15-ipad-narrower-columns.md).
/// `columns` fits as many columns as the quadrant's width allows; `list` is the one-column list.
/// The raw values are persisted per device, so they never change.
public enum MatrixLayout: String, CaseIterable, Sendable {
    case list, columns

    public static let `default`: MatrixLayout = .columns

    /// At this width a card's title has room beside both 44-point controls. Narrower cards in
    /// columns drop the menu button.
    public static let comfortableCardWidth: Double = 280
    /// Two cards this wide fit a 13-inch iPad's quadrant with the sidebar open. The narrowest
    /// measured is 470 points (a 1,366-point iPad on iOS 26.5, whose sidebar is 330 points),
    /// and two cards need exactly that.
    public static let compactCardWidth: Double = 227
    public static let columnSpacing: Double = 16

    /// The narrowest card Columns draws. The Mac draws the iPad layout at 77 percent scale, so
    /// its windows clear the comfortable width, and its cards always keep the menu button.
    public static func minimumCardWidth(onMac: Bool) -> Double {
        onMac ? comfortableCardWidth : compactCardWidth
    }

    /// Columns of cards for a quadrant whose content is `width` points wide. List, accessibility
    /// text sizes, and widths that aren't a real measurement (zero before first layout) get one.
    public func columnCount(forWidth width: Double, minimumCardWidth: Double, accessibilityTextSize: Bool) -> Int {
        guard self == .columns, !accessibilityTextSize, width.isFinite, width > 0 else { return 1 }
        let fit = (width + Self.columnSpacing) / (minimumCardWidth + Self.columnSpacing)
        return max(1, Int(fit.rounded(.down)))
    }

    /// Whether a card keeps its menu button when `columns` columns share `width` points. Under
    /// the comfortable width the button's 54 points go to the title. A one-column list always
    /// keeps it.
    public static func cardShowsMenu(forWidth width: Double, columns: Int) -> Bool {
        guard columns > 1 else { return true }
        let cardWidth = (width - Double(columns - 1) * columnSpacing) / Double(columns)
        return cardWidth >= comfortableCardWidth
    }
}
