import Testing
import GSDModel

/// The iOS 26 matrix card's swipe distances on cards of any width
/// (docs/2026-11-15-ipad-narrower-columns.md).
struct SwipeRevealMetricsTests {
    /// Half the row on a card 280 points or wider, which is what every card got before columns
    /// went under 280.
    @Test(arguments: zip([470.0, 320, 280], [235.0, 160, 140]))
    func aFullSwipeIsHalfAComfortableOrWiderCard(rowWidth: Double, expected: Double) {
        #expect(SwipeRevealMetrics.fullSwipeDistance(rowWidth: rowWidth) == expected)
    }

    /// Half of a 227-point card is 114 points, which an ordinary swipe passes. A narrow card
    /// keeps the 280-point card's 140.
    @Test(arguments: [279.0, 232, 227])
    func aFullSwipeOnANarrowCardStillTakes140Points(rowWidth: Double) {
        #expect(SwipeRevealMetrics.fullSwipeDistance(rowWidth: rowWidth) == 140)
    }

    /// Before the row is measured its width reads zero, and the old fallback was 210 points.
    @Test func anUnmeasuredRowKeepsTheOldFallback() {
        #expect(SwipeRevealMetrics.fullSwipeDistance(rowWidth: 0) == 210)
    }

    /// Two buttons fit every card in columns at full width, and three fit from 296 points up.
    @Test(arguments: zip([470.0, 227, 296, 470], [2, 2, 3, 3]))
    func trailingButtonsKeepTheirFullWidthWhenTheyFit(rowWidth: Double, buttons: Int) {
        #expect(SwipeRevealMetrics.trailingButtonWidth(rowWidth: rowWidth, buttons: buttons) == 84)
    }

    /// Three 84-point buttons are 252 points, wider than a 227-point card. They share what the
    /// close strip leaves: (227 − 44) / 3 = 61.
    @Test func threeButtonsShrinkToFitANarrowCard() {
        #expect(SwipeRevealMetrics.trailingButtonWidth(rowWidth: 227, buttons: 3) == 61)
    }

    @Test func anUnmeasuredRowGetsFullWidthButtons() {
        #expect(SwipeRevealMetrics.trailingButtonWidth(rowWidth: 0, buttons: 3) == 84)
    }

    /// The open row always shows a strip of the card to tap closed, and the buttons stay at
    /// least 44 points wide on every card Columns can draw.
    @Test func theOpenRowAlwaysLeavesACloseStrip() {
        for rowWidth in stride(from: 227.0, through: 600, by: 0.5) {
            for buttons in [2, 3] {
                let width = SwipeRevealMetrics.trailingButtonWidth(rowWidth: rowWidth, buttons: buttons)
                #expect(width * Double(buttons) <= rowWidth - SwipeRevealMetrics.closeStrip + 0.001,
                        "\(buttons) buttons on a \(rowWidth)-point row")
                #expect(width >= 44, "\(buttons) buttons on a \(rowWidth)-point row")
            }
        }
    }
}
