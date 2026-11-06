import Testing
import GSDModel

/// The iPad and Mac matrix layout setting (docs/2026-11-05-matrix-adaptive-columns.md).
struct MatrixLayoutTests {
    @Test func defaultIsColumns() {
        #expect(MatrixLayout.default == .columns)
    }

    /// Persisted in App Group defaults, so renaming a case would reset every device's choice.
    @Test func rawValuesArePinned() {
        #expect(MatrixLayout.list.rawValue == "list")
        #expect(MatrixLayout.columns.rawValue == "columns")
    }

    @Test func spacingAndMinimumMatchTheSpec() {
        #expect(MatrixLayout.minimumCardWidth == 280)
        #expect(MatrixLayout.columnSpacing == 16)
    }

    @Test(arguments: [0.0, 280, 576, 2000])
    func listIsAlwaysOneColumn(width: Double) {
        #expect(MatrixLayout.list.columnCount(forWidth: width, accessibilityTextSize: false) == 1)
    }

    /// Two columns need 2 × 280 + 16 = 576 points, three need 872, four need 1,168.
    @Test(arguments: zip([0.0, 279, 575, 576, 871, 872, 1168], [1, 1, 1, 2, 2, 3, 4]))
    func columnsFitCardsAtLeast280Wide(width: Double, expected: Int) {
        #expect(MatrixLayout.columns.columnCount(forWidth: width, accessibilityTextSize: false) == expected)
    }

    /// A width that isn't a real measurement gets one column instead of trapping in `Int(_:)`.
    @Test(arguments: [-10.0, .nan, .infinity])
    func degenerateWidthsGetOneColumn(width: Double) {
        #expect(MatrixLayout.columns.columnCount(forWidth: width, accessibilityTextSize: false) == 1)
    }

    /// Cards grow tall at accessibility text sizes, and narrow columns would clip them.
    @Test func accessibilityTextSizesGetOneColumn() {
        #expect(MatrixLayout.columns.columnCount(forWidth: 2000, accessibilityTextSize: true) == 1)
    }
}
