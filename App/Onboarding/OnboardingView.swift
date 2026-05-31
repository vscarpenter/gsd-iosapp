import SwiftUI

/// First-run onboarding (design-spec §3): a skippable, paged intro. The `hasOnboarded`
/// flag is owned by the presenter; this view just calls `onFinish` when done/skipped.
struct OnboardingView: View {
    var onFinish: () -> Void
    @State private var page = 0

    private struct Page: Identifiable {
        let id = UUID(); let icon: String; let title: String; let body: String
    }
    private let pages: [Page] = [
        .init(icon: "square.grid.2x2",
              title: String(localized: "Prioritize with the Matrix"),
              body: String(localized: "Sort tasks by urgency and importance across four quadrants.")),
        .init(icon: "keyboard",
              title: String(localized: "Capture fast"),
              body: String(localized: "Type while you capture: !! or ! marks a task urgent, * marks it important, and #tag adds a tag. For example, “Email Sam !! *  #work”.")),
        .init(icon: "line.3.horizontal.decrease.circle",
              title: String(localized: "Focus with Smart Views"),
              body: String(localized: "Browse built-in and custom views to see exactly what matters now.")),
        .init(icon: "chart.bar.xaxis",
              title: String(localized: "Track your progress"),
              body: String(localized: "The dashboard shows streaks, trends, and where your time goes.")),
        .init(icon: "lock.shield",
              title: String(localized: "Private by default"),
              body: String(localized: "No account required. Your data stays on your device; optional sync can come later.")),
    ]

    var body: some View {
        VStack {
            HStack {
                Spacer()
                Button(String(localized: "Skip"), action: onFinish)
                    .padding()
            }
            TabView(selection: $page) {
                ForEach(Array(pages.enumerated()), id: \.element.id) { index, p in
                    VStack(spacing: 16) {
                        Image(systemName: p.icon)
                            .font(.system(size: 52))
                            .foregroundStyle(.tint)
                        Text(p.title)
                            .font(.serif(.title))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(p.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 40)
                    .padding(.vertical, 16)
                    .tag(index)
                }
            }
            // Hide the built-in page dots: they overlay the bottom of the TabView frame
            // and collide with long body text. Render our own dot row below instead.
            .tabViewStyle(.page(indexDisplayMode: .never))

            HStack(spacing: 8) {
                ForEach(pages.indices, id: \.self) { index in
                    Circle()
                        .fill(index == page ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.top, 8)

            Button(action: advance) {
                Text(page == pages.count - 1 ? String(localized: "Get Started") : String(localized: "Next"))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding()
        }
    }

    private func advance() {
        if page < pages.count - 1 { withAnimation { page += 1 } } else { onFinish() }
    }
}
