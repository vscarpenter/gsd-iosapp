import Foundation

/// Distances for the iOS 26 matrix card's hand-rolled swipe (`SwipeRevealRow` in the app). A card
/// in columns can be narrower than its three trailing buttons, so each distance depends on the
/// row's width (docs/2026-11-15-ipad-narrower-columns.md). Retire this with `SwipeRevealRow`.
public enum SwipeRevealMetrics {
    public static let buttonWidth: Double = 84
    /// The strip of card left showing beside the open trailing buttons. A tap on it closes the row.
    public static let closeStrip: Double = 44

    /// How far a swipe right travels before it completes the task: half the row, and never less
    /// than half a comfortable card. Half of a 227-point card is 114 points, which an ordinary
    /// swipe passes. A row that isn't measured yet keeps the old 210-point fallback.
    public static func fullSwipeDistance(rowWidth: Double) -> Double {
        guard rowWidth > 0 else { return buttonWidth * 2.5 }
        return max(rowWidth, MatrixLayout.comfortableCardWidth) * 0.5
    }

    /// The width of each trailing button when `buttons` of them open on a row `rowWidth` points
    /// wide. They shrink to leave the close strip showing, and keep full width where they fit.
    public static func trailingButtonWidth(rowWidth: Double, buttons: Int) -> Double {
        guard rowWidth > 0, buttons > 0 else { return buttonWidth }
        return min(buttonWidth, (rowWidth - closeStrip) / Double(buttons))
    }
}
