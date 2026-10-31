import SwiftUI

/// The Matrix's first-frame placeholder, shown until the store's first task snapshot lands
/// (`TaskStore.hasLoadedTasks`). Before it, a cold start flashed "Capture your first task"
/// (iPhone) or four empty quadrants (iPad) for the frames between first render and that
/// snapshot, a state that wasn't true yet. Its own views: the cards belong to E-IOS-ESC.

/// iPhone: four stacked quadrant sections in the inset-grouped silhouette.
struct MatrixListSkeleton: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                ForEach(0..<4, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 10) {
                        SkeletonBlock(height: 14, width: 120, radius: 4)
                        VStack(spacing: 8) {
                            SkeletonBlock(height: 54, radius: Radius.card)
                            SkeletonBlock(height: 54, radius: Radius.card)
                        }
                    }
                }
            }
            .padding(.horizontal, 20).padding(.top, 24)
            .skeletonShimmer()
        }
        .scrollDisabled(true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Loading"))
    }
}

/// iPad and Mac: the 2x2 grid of quadrant panels.
struct MatrixGridSkeleton: View {
    var body: some View {
        Grid(horizontalSpacing: 16, verticalSpacing: 16) {
            ForEach(0..<2, id: \.self) { _ in
                GridRow {
                    ForEach(0..<2, id: \.self) { _ in
                        SkeletonBlock(height: 220, radius: Radius.card)
                            .frame(maxHeight: .infinity)
                    }
                }
            }
        }
        .padding(12)
        .skeletonShimmer()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Surface.paper)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Loading"))
    }
}
