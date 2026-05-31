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
                    VStack(spacing: 20) {
                        Image(systemName: p.icon)
                            .font(.system(size: 64))
                            .foregroundStyle(.tint)
                        Text(p.title).font(.serif(.title)).multilineTextAlignment(.center)
                        Text(p.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .padding(40)
                    .tag(index)
                }
            }
            .tabViewStyle(.page)
            .indexViewStyle(.page(backgroundDisplayMode: .always))

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
