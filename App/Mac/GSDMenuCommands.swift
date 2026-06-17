import SwiftUI
import GSDModel
import GSDSnapshot

/// Mac-only menu-bar commands. Each item drives the SAME navigation the in-window
/// ⌘-shortcuts and deep links already use (DeepLinkHandoff → .gsdOpenDeepLink →
/// ContentView), so the menu bar reuses the app's routing instead of duplicating it.
struct GSDMenuCommands: Commands {
    var body: some Commands {
        // Replace the stock "About GSD" with our editorial panel (ContentView shows the sheet).
        CommandGroup(replacing: .appInfo) {
            Button(String(localized: "About GSD")) {
                NotificationCenter.default.post(name: .gsdShowAbout, object: nil)
            }
        }
        // Replace the default File ▸ New with "New Task" (⌘N).
        CommandGroup(replacing: .newItem) {
            Button(String(localized: "New Task")) {
                DeepLinkHandoff.open(.capture)
            }
            .keyboardShortcut("n", modifiers: .command)
        }
        // Top-level "View" menu mirroring the quadrant/navigation shortcuts.
        CommandMenu(String(localized: "View")) {
            Button(String(localized: "Find…")) {
                NotificationCenter.default.post(name: .gsdShowCommandPalette, object: nil)
            }
            .keyboardShortcut("k", modifiers: .command)
            Divider()
            Button(String(localized: "Today's Focus")) { DeepLinkHandoff.open(.focus) }
            Divider()
            Button(Quadrant.urgentImportant.title) { DeepLinkHandoff.open(.quadrant(.urgentImportant)) }
                .keyboardShortcut("1", modifiers: .command)
            Button(Quadrant.notUrgentImportant.title) { DeepLinkHandoff.open(.quadrant(.notUrgentImportant)) }
                .keyboardShortcut("2", modifiers: .command)
            Button(Quadrant.urgentNotImportant.title) { DeepLinkHandoff.open(.quadrant(.urgentNotImportant)) }
                .keyboardShortcut("3", modifiers: .command)
            Button(Quadrant.notUrgentNotImportant.title) { DeepLinkHandoff.open(.quadrant(.notUrgentNotImportant)) }
                .keyboardShortcut("4", modifiers: .command)
            Divider()
            Button(String(localized: "Dashboard")) { DeepLinkHandoff.open(.dashboard) }
            Button(String(localized: "Archive")) { DeepLinkHandoff.open(.archive) }
            Button(String(localized: "Settings")) { DeepLinkHandoff.open(.settings) }
        }
    }
}

/// The Mac "About GSD" panel (app menu ▸ About GSD), shown as a sheet from `ContentView`.
/// Mirrors the onboarding's editorial language — the app mark, a New York serif tagline, a calm
/// one-line description, the version, and a link to the web app. Reads no `@Observable` env, so it
/// needs no Catalyst re-injection.
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(v) (\(b))"
    }

    var body: some View {
        VStack(spacing: 16) {
            AppMark().frame(width: 76, height: 76)
            Text(String(localized: "Get the right things done."))
                .font(.serif(.title2).weight(.semibold))
                .foregroundStyle(Surface.ink)
            Text(String(localized: "GSD turns the Eisenhower matrix into a calm place to decide what matters, then do it."))
                .font(.body)
                .foregroundStyle(Surface.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Text("Version \(appVersion)")
                .font(.footnote)
                .foregroundStyle(Surface.ink3)
            Link(String(localized: "gsdtaskmanager.com"), destination: URL(string: "https://gsdtaskmanager.com/")!)
                .font(.callout.weight(.medium))
                .foregroundStyle(Surface.tint)   // the one genuine action in the panel → the interactive tint
                .padding(.top, 4)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 40)
        .padding(.top, 44)
        .padding(.bottom, 32)
        .frame(width: 380)
        .background(Surface.paper)
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Surface.ink3)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .padding(12)
        }
    }
}
