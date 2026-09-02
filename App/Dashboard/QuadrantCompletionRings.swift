import SwiftUI
import GSDModel

/// Four concentric completion rings, Q1 outermost, in the quadrant pigments — the one
/// §6.15 metric (per-quadrant completion rate) the dashboard didn't show. Adapted from
/// ShipSwift's `SWRingChart` (MIT — THIRD_PARTY_NOTICES.md): the track is the quadrant's
/// wash rather than a 15% tint, the legend is the donut card's 2×2 grid, the grow-in is
/// skipped under Reduce Motion, and the rings are one accessibility element instead of
/// eight arcs — the legend rows carry the per-quadrant values for VoiceOver.
struct QuadrantCompletionRings: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Always four, Q1→Q4 (`AnalyticsSummary.quadrantStats`).
    let stats: [AnalyticsSummary.QuadrantStat]
    /// The all-quadrant rate, shown in the center.
    let overallRate: Double
    /// 0→1 multiplier on every ring's trim, so the appear animation grows all four together.
    @State private var growth: Double = 0

    private let size: CGFloat = 196
    private let ringWidth: CGFloat = 13
    private let gap: CGFloat = 5

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                ForEach(Array(stats.enumerated()), id: \.element.id) { index, stat in
                    let diameter = size - CGFloat(index) * (ringWidth + gap) * 2
                    Circle()
                        .stroke(QuadrantStyle.wash(stat.quadrant), lineWidth: ringWidth)
                        .frame(width: diameter, height: diameter)
                    Circle()
                        .trim(from: 0, to: stat.completionRate * growth)
                        .stroke(QuadrantStyle.accent(stat.quadrant),
                                style: StrokeStyle(lineWidth: ringWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: diameter, height: diameter)
                }
                VStack(spacing: 2) {
                    Text(Self.percent(overallRate))
                        .font(.serif(.title2).weight(.semibold)).monospacedDigit()
                        .foregroundStyle(Surface.ink)
                        .lineLimit(1).minimumScaleFactor(0.6)   // the inner hole is ~75pt; keep large Dynamic Type inside it
                    Text(String(localized: "complete")).font(.caption).foregroundStyle(Surface.ink3)
                }
                .frame(width: size - 3 * (ringWidth + gap) * 2 - ringWidth - 8)
            }
            .frame(width: size, height: size)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(localized: "Completion rings, \(Self.percent(overallRate)) of all tasks complete"))

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(stats) { stat in
                    HStack(spacing: 9) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(QuadrantStyle.accent(stat.quadrant)).frame(width: 11, height: 11)
                        Text(stat.quadrant.title).font(.subheadline).foregroundStyle(Surface.ink2)
                        Spacer()
                        Text(legendValue(stat)).font(.subheadline.weight(.semibold)).monospacedDigit()
                            .foregroundStyle(Surface.ink)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(String(localized: "\(stat.quadrant.title): \(legendSpokenValue(stat))"))
                }
            }
        }
        .onAppear {
            if reduceMotion { growth = 1 } else { withAnimation(.easeOut(duration: 0.9)) { growth = 1 } }
        }
    }

    /// An em-dash when a quadrant has no tasks at all: "0% complete" of nothing is a
    /// cryptic zero (the same call the Tracked stat card makes for its zero-state).
    private func legendValue(_ stat: AnalyticsSummary.QuadrantStat) -> String {
        stat.total == 0 ? "—" : Self.percent(stat.completionRate)
    }

    private func legendSpokenValue(_ stat: AnalyticsSummary.QuadrantStat) -> String {
        stat.total == 0
            ? String(localized: "no tasks")
            : String(localized: "\(Self.percent(stat.completionRate)) complete")
    }

    private static func percent(_ rate: Double) -> String { "\(Int((rate * 100).rounded()))%" }
}
