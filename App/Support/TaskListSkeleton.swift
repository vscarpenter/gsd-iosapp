import SwiftUI

/// Placeholder rows in an inset-grouped list's silhouette, shown until the store's first
/// task snapshot lands (`TaskStore.hasLoadedTasks`) so a smart view opened on a cold start
/// doesn't flash "Nothing here yet." before its rows exist.
struct TaskListSkeleton: View {
    var rows: Int = 6

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(0..<rows, id: \.self) { index in
                    HStack(spacing: 12) {
                        Circle().fill(Surface.sunken).frame(width: 22, height: 22)
                        VStack(alignment: .leading, spacing: 7) {
                            SkeletonBlock(height: 14, width: index.isMultiple(of: 2) ? 210 : 150, radius: 4)
                            SkeletonBlock(height: 10, width: 96, radius: 4)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 14)
                    if index < rows - 1 {
                        Rectangle().fill(Surface.hairline).frame(height: 1).padding(.leading, 50)
                    }
                }
            }
            .background(Surface.surface, in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
            .padding(.horizontal, 16).padding(.top, 20)
            .skeletonShimmer()
        }
        .scrollDisabled(true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Loading"))
    }
}
