import Foundation

/// How the iPad and Mac matrix lays out each quadrant's cards (docs/2026-11-05-matrix-adaptive-columns.md).
/// `columns` fits as many columns as the quadrant's width allows; `list` is the one-column list.
/// The raw values are persisted per device, so they never change.
public enum MatrixLayout: String, CaseIterable, Sendable {
    case list, columns

    public static let `default`: MatrixLayout = .columns

    /// Below this a card's title shares its row with two 44-point controls and wraps early.
    public static let minimumCardWidth: Double = 280
    public static let columnSpacing: Double = 16

    /// Columns of cards for a quadrant whose content is `width` points wide. List, accessibility
    /// text sizes, and widths that aren't a real measurement (zero before first layout) get one.
    public func columnCount(forWidth width: Double, accessibilityTextSize: Bool) -> Int {
        guard self == .columns, !accessibilityTextSize, width.isFinite, width > 0 else { return 1 }
        let fit = (width + Self.columnSpacing) / (Self.minimumCardWidth + Self.columnSpacing)
        return max(1, Int(fit.rounded(.down)))
    }
}
