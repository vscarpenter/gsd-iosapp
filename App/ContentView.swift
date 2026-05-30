import SwiftUI

/// Adaptive root: stacked matrix on compact width (iPhone), 2×2 grid on regular (iPad).
struct ContentView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        if sizeClass == .compact {
            MatrixView()
        } else {
            MatrixGridView()
        }
    }
}
