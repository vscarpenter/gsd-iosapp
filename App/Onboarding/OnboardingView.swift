import SwiftUI
import GSDModel

/// First-run onboarding (design §9): four skippable, paged screens in the editorial
/// language — paper background, New York titles, an ink-filled primary pill, and the
/// single tint reserved for optional sync sign-in. `hasOnboarded` is owned by
/// the presenter; this view calls `onFinish` (done/skipped) or a provider sign-in.
struct OnboardingView: View {
    var onFinish: () -> Void
    var onGoogleSignIn: (() -> Void)? = nil
    var onAppleSignIn: (() -> Void)? = nil

    @State private var page = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private let pageCount = 4

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button(String(localized: "Skip"), action: onFinish)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Surface.ink3)
                    .padding()
            }

            TabView(selection: $page) {
                welcomeScreen.tag(0)
                matrixScreen.tag(1)
                captureScreen.tag(2)
                privacyScreen.tag(3)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            dots.padding(.vertical, 14)
            footer.padding(.horizontal, 28).padding(.bottom, 24)
        }
        .background(Surface.paper)
    }

    // MARK: chrome

    private var dots: some View {
        HStack(spacing: 7) {
            ForEach(0..<pageCount, id: \.self) { i in
                Capsule()
                    .fill(i == page ? Surface.ink : Surface.hairlineStrong)
                    .frame(width: i == page ? 22 : 7, height: 7)
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder private var footer: some View {
        if page < pageCount - 1 {
            primaryButton(page == 0 ? String(localized: "Get started") : String(localized: "Next")) {
                withAnimation(reduceMotion ? nil : .easeInOut) { page += 1 }
            }
        } else {
            VStack(spacing: 8) {
                primaryButton(String(localized: "Start using GSD"), action: onFinish)
                if onAppleSignIn != nil || onGoogleSignIn != nil {
                    syncSignInButtons
                    Text(String(localized: "To sync with the web app and your other devices, use the same email you use there."))
                        .font(.caption)
                        .foregroundStyle(Surface.ink3)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder private var syncSignInButtons: some View {
        if let onAppleSignIn {
            // Apple HIG-styled button driving the same web-redirect flow as Google (Option A).
            // `SignInWithAppleButton` can't be reused — it always triggers the retired native sheet —
            // so the appearance rules (black-on-light / white-on-dark, Apple glyph, wording, corner
            // radius) are hand-rendered to satisfy App Review Guideline 4.8 (same as SettingsView).
            Button(action: onAppleSignIn) {
                Label(String(localized: "Sign in with Apple"), systemImage: "applelogo")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .foregroundStyle(colorScheme == .dark ? .black : .white)
                    .background(colorScheme == .dark ? Color.white : Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
        }

        if let onGoogleSignIn {
            Button(action: onGoogleSignIn) {
                Text(String(localized: "Sign in with Google"))
                    .font(.callout.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .foregroundStyle(Surface.tint)
            }
            .buttonStyle(.plain)
        }
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.body.weight(.semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 15)
                .background(Surface.ink, in: Capsule())
                .foregroundStyle(Surface.paper)
        }
        .buttonStyle(.plain)
    }

    // MARK: screens

    private var welcomeScreen: some View {
        screen(title: String(localized: "Get the right things done."),
               lead: String(localized: "A calm place to sort what's urgent and important — and let go of what isn't.")) {
            AppMark().frame(width: 92, height: 92)
        }
    }

    private var matrixScreen: some View {
        screen(title: String(localized: "Four quadrants, one decision."),
               lead: String(localized: "Every task lands by how urgent and how important it is.")) {
            AxesDiagram()
        }
    }

    private var captureScreen: some View {
        screen(title: String(localized: "Capture in one line."),
               lead: String(localized: "Type shorthand as you go and GSD files it for you.")) {
            CaptureLegend()
        }
    }

    private var privacyScreen: some View {
        screen(title: String(localized: "Yours, and only yours."),
               lead: String(localized: "No account required. Your tasks stay on this device unless you choose to sign in and sync.")) {
            ZStack {
                Circle().fill(Surface.sunken).frame(width: 92, height: 92)
                Image(systemName: "lock.fill").font(.system(size: 38)).foregroundStyle(Surface.ink2)
            }
        }
    }

    private func screen<Hero: View>(title: String, lead: String,
                                    @ViewBuilder hero: () -> Hero) -> some View {
        VStack(spacing: 18) {
            hero().padding(.bottom, 6)
            Text(title).font(.serif(.title).weight(.semibold))
                .foregroundStyle(Surface.ink)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Text(lead).font(.body).foregroundStyle(Surface.ink2)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 300)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 36)
    }
}

// MARK: - Illustrations (SF-symbol-free, drawn from the design tokens)

/// The 2×2 app mark: four pigment tiles with a single white check on the Do-First tile.
/// Shared with the Mac "About GSD" panel (`GSDMenuCommands`).
struct AppMark: View {
    var body: some View {
        GeometryReader { geo in
            let gap = geo.size.width * 0.07
            let tile = (geo.size.width - gap) / 2
            VStack(spacing: gap) {
                HStack(spacing: gap) {
                    pigment(.urgentImportant, check: true).frame(width: tile, height: tile)
                    pigment(.notUrgentImportant).frame(width: tile, height: tile)
                }
                HStack(spacing: gap) {
                    pigment(.urgentNotImportant).frame(width: tile, height: tile)
                    pigment(.notUrgentNotImportant).frame(width: tile, height: tile)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func pigment(_ q: Quadrant, check: Bool = false) -> some View {
        RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
            .fill(QuadrantStyle.accent(q))
            .overlay {
                if check {
                    Image(systemName: "checkmark").font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Surface.inkOnAccent)
                }
            }
    }
}

/// A 2×2 of pigment-wash tiles with urgency/importance axis labels.
private struct AxesDiagram: View {
    var body: some View {
        HStack(spacing: 8) {
            Text(String(localized: "More important →"))
                .font(.caption.weight(.semibold)).foregroundStyle(Surface.ink3)
                .fixedSize().rotationEffect(.degrees(-90)).frame(width: 18)
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    tile(.urgentImportant, String(localized: "Do First"))
                    tile(.notUrgentImportant, String(localized: "Schedule"))
                }
                HStack(spacing: 8) {
                    tile(.urgentNotImportant, String(localized: "Delegate"))
                    tile(.notUrgentNotImportant, String(localized: "Eliminate"))
                }
                Text(String(localized: "More urgent →"))
                    .font(.caption.weight(.semibold)).foregroundStyle(Surface.ink3)
            }
        }
        .frame(width: 268)
        .accessibilityHidden(true)
    }

    private func tile(_ q: Quadrant, _ name: String) -> some View {
        Text(name)
            .font(.serif(.subheadline).weight(.semibold))
            .foregroundStyle(QuadrantStyle.accent(q))
            .frame(maxWidth: .infinity, minHeight: 62, alignment: .topLeading)
            .padding(11)
            .background(QuadrantStyle.wash(q), in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
    }
}

/// A sample capture field plus a legend mapping the shorthand tokens.
private struct CaptureLegend: View {
    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 0) {
                Text("Call my wife ").foregroundStyle(Surface.ink)
                Text("!!").font(.system(.body, design: .monospaced).weight(.semibold))
                    .foregroundStyle(QuadrantStyle.accent(.urgentImportant))
                Text("  ").foregroundStyle(Surface.ink)
                Text("#family").font(.system(.footnote, design: .monospaced).weight(.semibold))
                    .foregroundStyle(QuadrantStyle.accent(.urgentImportant))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(QuadrantStyle.wash(.urgentImportant), in: Capsule())
                Spacer(minLength: 0)
            }
            .font(.body)
            .padding(.vertical, 13).padding(.horizontal, 18)
            .background(Surface.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(Surface.hairline))

            VStack(spacing: 10) {
                legendRow("!!", String(localized: "Urgent & important"))
                legendRow("!", String(localized: "Urgent"))
                legendRow("*", String(localized: "Important"))
                legendRow("#tag", String(localized: "Add a tag"))
            }
        }
        .frame(maxWidth: 280)
        .accessibilityHidden(true)
    }

    private func legendRow(_ token: String, _ meaning: String) -> some View {
        HStack(spacing: 12) {
            Text(token)
                .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                .foregroundStyle(Surface.ink)
                .frame(minWidth: 46).padding(.vertical, 6)
                .background(Surface.sunken, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
            Text(meaning).font(.subheadline).foregroundStyle(Surface.ink2)
            Spacer(minLength: 0)
        }
    }
}
