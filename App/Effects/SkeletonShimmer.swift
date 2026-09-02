import SwiftUI

/// A placeholder block for content that hasn't loaded: sunken fill, continuous corners.
/// Compose blocks into the real layout's silhouette, then apply `.skeletonShimmer()` to
/// the whole composition so one band sweeps everything rather than each block separately.
struct SkeletonBlock: View {
    var height: CGFloat
    var width: CGFloat? = nil
    var radius: CGFloat = Radius.small

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Surface.sunken)
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }
}

/// A slow light band sweeping across skeleton placeholders. Adapted from ShipSwift's
/// `SWShimmer` (MIT — THIRD_PARTY_NOTICES.md) with three changes: the band is the raised
/// `Surface.surface` tone (a white band reads as glare on warm paper and vanishes in dark
/// mode); it is masked to the content's own shapes so it never streaks across the gaps;
/// and Reduce Motion removes the sweep entirely — the skeleton stays static (§6.4/§12.3).
struct SkeletonShimmer: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweep = false
    var duration: Double = 1.6
    var pause: Double = 0.6

    func body(content: Content) -> some View {
        content
            .overlay {
                if !reduceMotion {
                    GeometryReader { geo in
                        let band = geo.size.width * 0.5
                        LinearGradient(colors: [.clear, Surface.surface.opacity(0.75), .clear],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: band)
                            .offset(x: sweep ? geo.size.width + band : -band)
                            .animation(.linear(duration: duration).delay(pause).repeatForever(autoreverses: false),
                                       value: sweep)
                    }
                    .mask { content }
                    .allowsHitTesting(false)
                }
            }
            .task {
                guard !reduceMotion else { return }
                // One frame's grace so the band starts from a settled layout (ShipSwift's note).
                try? await _Concurrency.Task.sleep(for: .milliseconds(100))
                sweep = true
            }
    }
}

extension View {
    func skeletonShimmer() -> some View { modifier(SkeletonShimmer()) }
}
