import Testing
import GSDModel

/// The iPad and Mac matrix layout setting (docs/2026-11-05-matrix-adaptive-columns.md,
/// docs/2026-11-15-ipad-narrower-columns.md).
struct MatrixLayoutTests {
    private static let iPad = MatrixLayout.minimumCardWidth(onMac: false)
    private static let mac = MatrixLayout.minimumCardWidth(onMac: true)

    @Test func defaultIsColumns() {
        #expect(MatrixLayout.default == .columns)
    }

    /// Persisted in App Group defaults, so renaming a case would reset every device's choice.
    @Test func rawValuesArePinned() {
        #expect(MatrixLayout.list.rawValue == "list")
        #expect(MatrixLayout.columns.rawValue == "columns")
    }

    @Test func spacingAndCardWidthsMatchTheSpec() {
        #expect(MatrixLayout.comfortableCardWidth == 280)
        #expect(MatrixLayout.compactCardWidth == 227)
        #expect(MatrixLayout.columnSpacing == 16)
    }

    /// The Mac draws the iPad layout at 77 percent scale, so its windows already clear 280.
    @Test func theMacKeepsTheComfortableMinimumAndTheIPadGetsTheCompactOne() {
        #expect(Self.mac == 280)
        #expect(Self.iPad == 227)
    }

    @Test(arguments: [0.0, 227, 470, 576, 2000])
    func listIsAlwaysOneColumn(width: Double) {
        #expect(MatrixLayout.list.columnCount(forWidth: width, minimumCardWidth: Self.iPad,
                                              accessibilityTextSize: false) == 1)
    }

    /// Two columns need 2 × 280 + 16 = 576 points, three need 872, four need 1,168.
    @Test(arguments: zip([0.0, 279, 575, 576, 871, 872, 1168], [1, 1, 1, 2, 2, 3, 4]))
    func macColumnsFitCardsAtLeast280Wide(width: Double, expected: Int) {
        #expect(MatrixLayout.columns.columnCount(forWidth: width, minimumCardWidth: Self.mac,
                                                 accessibilityTextSize: false) == expected)
    }

    /// Two columns need 2 × 227 + 16 = 470 points, and three need 713.
    @Test(arguments: zip([0.0, 226, 469, 470, 712, 713], [1, 1, 1, 2, 2, 3]))
    func iPadColumnsFitCardsAtLeast227Wide(width: Double, expected: Int) {
        #expect(MatrixLayout.columns.columnCount(forWidth: width, minimumCardWidth: Self.iPad,
                                                 accessibilityTextSize: false) == expected)
    }

    /// Quadrant widths on iPads in landscape, sidebar open then hidden. Two are measured: 480 on
    /// the 13-inch iPad Pro whose Columns button did nothing (320-point sidebar), and 470 on a
    /// 13-inch iPad Air simulator on iOS 26.5 (330-point sidebar). The rest are arithmetic:
    /// (screen − sidebar − 40) / 2 − 28. In order: three 13-inch widths with the sidebar open,
    /// one with it hidden, two 11-inch widths with it hidden, and two with it open.
    @Test(arguments: zip([480.0, 475, 470, 640, 557, 542, 397, 382], [2, 2, 2, 2, 2, 2, 1, 1]))
    func iPadQuadrantsGetTheColumnsThatFit(width: Double, expected: Int) {
        #expect(MatrixLayout.columns.columnCount(forWidth: width, minimumCardWidth: Self.iPad,
                                                 accessibilityTextSize: false) == expected)
    }

    /// A 13-inch iPad in portrait is 468 points on the Pro and 464 on the Air. Two columns there
    /// is an open question for the owner, so portrait holds at one.
    @Test(arguments: [468.0, 464])
    func thirteenInchPortraitStaysAtOneColumn(width: Double) {
        #expect(MatrixLayout.columns.columnCount(forWidth: width, minimumCardWidth: Self.iPad,
                                                 accessibilityTextSize: false) == 1)
    }

    /// A width that isn't a real measurement gets one column instead of trapping in `Int(_:)`.
    @Test(arguments: [-10.0, .nan, .infinity])
    func degenerateWidthsGetOneColumn(width: Double) {
        #expect(MatrixLayout.columns.columnCount(forWidth: width, minimumCardWidth: Self.iPad,
                                                 accessibilityTextSize: false) == 1)
    }

    /// Cards grow tall at accessibility text sizes, and narrow columns would clip them.
    @Test func accessibilityTextSizesGetOneColumn() {
        #expect(MatrixLayout.columns.columnCount(forWidth: 2000, minimumCardWidth: Self.iPad,
                                                 accessibilityTextSize: true) == 1)
    }

    /// A card under 280 points gives its menu button's room to the title: two 232-point cards
    /// on a 13-inch iPad, two at 279.5, and three at 227.
    @Test(arguments: zip([480.0, 575, 713], [2, 2, 3]))
    func cardsUnder280DropTheMenuButton(width: Double, columns: Int) {
        #expect(!MatrixLayout.cardShowsMenu(forWidth: width, columns: columns))
    }

    /// Cards 280 and wider keep it, and so does every one-column list, however narrow.
    @Test(arguments: zip([576.0, 640, 872, 480, 200], [2, 2, 3, 1, 1]))
    func widerCardsAndListsKeepTheMenuButton(width: Double, columns: Int) {
        #expect(MatrixLayout.cardShowsMenu(forWidth: width, columns: columns))
    }

    /// The Mac's minimum is the menu button's threshold, so no Mac window ever hides the button.
    @Test func theMacNeverDropsTheMenuButton() {
        for width in stride(from: 100.0, through: 4000, by: 1) {
            let columns = MatrixLayout.columns.columnCount(forWidth: width, minimumCardWidth: Self.mac,
                                                           accessibilityTextSize: false)
            #expect(MatrixLayout.cardShowsMenu(forWidth: width, columns: columns),
                    "a \(width)-point quadrant in \(columns) columns")
        }
    }
}
