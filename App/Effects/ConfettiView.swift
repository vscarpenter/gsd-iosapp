import SwiftUI

/// A one-shot confetti burst, fired by incrementing `trigger`. Honors Reduce
/// Motion (§6.4/§12.3): no particles emitted when it's on. Particle counts are a
/// feel reference, freely tunable.
struct ConfettiView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let trigger: Int

    @State private var particles: [Particle] = []
    @State private var startDate: Date?

    private static let duration: TimeInterval = 1.6

    var body: some View {
        TimelineView(.animation(paused: startDate == nil)) { timeline in
            Canvas { context, size in
                guard let start = startDate else { return }
                let t = timeline.date.timeIntervalSince(start)
                if t > Self.duration { return }
                for p in particles {
                    let pos = p.position(at: t, in: size)
                    var ctx = context
                    ctx.opacity = max(0, 1 - t / Self.duration)
                    ctx.fill(Path(ellipseIn: CGRect(x: pos.x, y: pos.y, width: p.size, height: p.size)),
                             with: .color(p.color))
                }
            }
        }
        .allowsHitTesting(false)
        .onChange(of: trigger) { _, _ in fire() }
    }

    private func fire() {
        guard !reduceMotion else { return }
        particles = (0..<160).map { _ in Particle.random() }
        startDate = .now
    }

    struct Particle {
        var origin: CGPoint          // normalized 0...1
        var velocity: CGVector
        var color: Color
        var size: CGFloat
        func position(at t: TimeInterval, in size: CGSize) -> CGPoint {
            let gravity = 700.0
            return CGPoint(x: origin.x * size.width + velocity.dx * t,
                           y: origin.y * size.height + velocity.dy * t + 0.5 * gravity * t * t)
        }
        static func random() -> Particle {
            // On-brand celebration: the four quadrant pigments + success green, no generic rainbow.
            let colors: [Color] = [
                QuadrantStyle.accent(.urgentImportant), QuadrantStyle.accent(.notUrgentImportant),
                QuadrantStyle.accent(.urgentNotImportant), QuadrantStyle.accent(.notUrgentNotImportant),
                Surface.success,
            ]
            let angle = Double.random(in: 0..<2 * .pi)
            let speed = Double.random(in: 150...460)
            return Particle(origin: CGPoint(x: Double.random(in: 0.3...0.7), y: 0.45),
                            velocity: CGVector(dx: cos(angle) * speed, dy: sin(angle) * speed - 220),
                            color: colors.randomElement()!, size: .random(in: 5...10))
        }
    }
}
