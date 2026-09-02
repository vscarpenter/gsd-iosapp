import SwiftUI

/// The Dashboard's first-frame placeholder: the stat grid and the first two cards as
/// sunken blocks, shown only until the store's first task snapshot lands
/// (`TaskStore.hasLoadedTasks`). Before it, a cold start flashed "No stats yet" for the
/// frames between first render and that snapshot — an empty state that wasn't true yet.
struct DashboardSkeleton: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 11) {
                    ForEach(0..<4, id: \.self) { _ in SkeletonBlock(height: 86, radius: Radius.input) }
                }
                SkeletonBlock(height: 270, radius: Radius.card)
                SkeletonBlock(height: 320, radius: Radius.card)
            }
            .padding(20)
            .skeletonShimmer()
        }
        .scrollDisabled(true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Loading"))
    }
}
