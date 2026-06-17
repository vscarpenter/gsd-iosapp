import SwiftUI
import UIKit
import GSDModel

/// The cross-platform "Field Guide" — a static reference sheet mirroring the web
/// help drawer (gsd.vinny.dev). Shown from Settings ▸ About on every platform and
/// from the Mac Help menu (⌘?). Reads no `@Observable` env (pure content), so —
/// like `AboutView` — it needs no Catalyst re-injection. Presented as a sheet owned
/// by `ContentView` via the `.gsdShowHelp` notification.
struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Pinned close bar so the dismiss target is always reachable while the
            // guide scrolls (Esc also dismisses via `.cancelAction`).
            HStack {
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Surface.ink3)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel(String(localized: "Close"))
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    header
                    boardSection
                    quadrantsSection
                    syntaxSection
                    if showsKeyboardShortcuts { shortcutsSection }
                    gesturesSection
                    syncSection
                    privacySection
                    footer
                }
                .frame(maxWidth: 520, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 4)
                .padding(.bottom, 44)
            }
        }
        .background(Surface.paper)
        #if targetEnvironment(macCatalyst)
        .frame(width: 480, height: 680)
        #endif
    }

    // MARK: header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "FIELD GUIDE"))
                .font(.caption.weight(.semibold))
                .tracking(1.4)
                .foregroundStyle(Surface.ink3)
            Text(String(localized: "How to use GSD"))
                .font(.serif(.largeTitle).weight(.semibold))
                .foregroundStyle(Surface.ink)
            // Hairline rule turns the masthead into a title bar so the body reads as help,
            // not a continuation of the headline.
            Rectangle()
                .fill(Surface.hairline)
                .frame(height: 1)
                .padding(.top, 12)
        }
    }

    // MARK: §1 one board, one capture bar

    private var boardSection: some View {
        section(String(localized: "ONE BOARD, ONE CAPTURE BAR"), icon: "square.grid.2x2") {
            ruledItem(
                title: String(localized: "The matrix"),
                body: String(localized: "The classic 2×2 Eisenhower board is your home view. Drag a task between quadrants to reclassify it.")
            )
            ruledItem(
                title: String(localized: "The capture bar"),
                body: String(localized: "Every task starts in the bar at the top. Type your task, and the parser routes it to the right quadrant based on the ! / * markers you include.")
            )
        }
    }

    // MARK: §2 the four quadrants

    private var quadrantsSection: some View {
        section(String(localized: "THE FOUR QUADRANTS"), icon: "circle.grid.2x2", carded: false) {
            ForEach(Quadrant.allCases, id: \.self) { q in
                QuadrantGuideRow(quadrant: q, blurb: Self.quadrantBlurb(q))
            }
        }
    }

    /// One-line meanings, mirroring the web field guide. Kept here (not on the model)
    /// because they are presentation copy; the Q1→Q4 ordering stays the model's job.
    private static func quadrantBlurb(_ q: Quadrant) -> String {
        switch q {
        case .urgentImportant:
            String(localized: "Urgent & important — crises, deadlines. Handle now.")
        case .notUrgentImportant:
            String(localized: "Important, not urgent — strategy, growth. Protect time.")
        case .urgentNotImportant:
            String(localized: "Urgent, not important — interruptions. Hand these off.")
        case .notUrgentNotImportant:
            String(localized: "Neither — noise. Stop doing these.")
        }
    }

    // MARK: §3 quick-add smart syntax

    private var syntaxSection: some View {
        section(String(localized: "QUICK-ADD SMART SYNTAX"), icon: "text.cursor") {
            Text(String(localized: "Type into the capture bar. GSD parses priority markers from your text as you type, and the dot on the left previews which quadrant the task will land in."))
                .font(.callout)
                .foregroundStyle(Surface.ink2)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                SyntaxRow(token: "!", meaning: String(localized: "Marks the task urgent"))
                SyntaxRow(token: "!!", meaning: String(localized: "Urgent and important (Do First)"))
                SyntaxRow(token: "*", meaning: String(localized: "Marks the task important"))
                SyntaxRow(token: "#tag", meaning: String(localized: "Adds a tag — any word-like token"))
            }
            .padding(.top, 2)

            exampleBlock
        }
    }

    private var exampleBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("!! ship the deck #work #q2")
                .font(.system(.subheadline, design: .monospaced).weight(.medium))
                .foregroundStyle(Surface.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Surface.sunken, in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
            Text(String(localized: "Creates an urgent + important task tagged #work and #q2."))
                .font(.footnote)
                .foregroundStyle(Surface.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 2)
    }

    // MARK: §4 keyboard shortcuts (Mac / iPad only)

    private var shortcutsSection: some View {
        section(String(localized: "KEYBOARD SHORTCUTS"), icon: "keyboard") {
            VStack(alignment: .leading, spacing: 10) {
                ShortcutRow(keys: ["⌘", "K"], label: String(localized: "Open the command palette"))
                ShortcutRow(keys: ["⌘", "F"], label: String(localized: "Open the command palette to search"))
                ShortcutRow(keys: ["⌘", "N"], label: String(localized: "New task"))
                ShortcutRow(keys: ["⌘", "1–4"], label: String(localized: "Jump to a quadrant"))
                ShortcutRow(keys: ["⌘", "?"], label: String(localized: "Open this field guide"))
                ShortcutRow(keys: ["esc"], label: String(localized: "Close any sheet or drawer"))
            }
            Text(String(localized: "⌘F is left to the system text-find layer on Mac. Shortcuts are suppressed while you're typing in a field, so the capture bar won't hijack keys."))
                .font(.footnote)
                .foregroundStyle(Surface.ink3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
    }

    // MARK: §5 editing, completing, drag-drop (all platforms)

    private var gesturesSection: some View {
        section(String(localized: "EDITING, COMPLETING & DRAG-DROP"), icon: "hand.draw") {
            ruledItem(
                title: String(localized: "Complete"),
                body: String(localized: "Tap the checkbox on any task card. Recurring tasks automatically spawn the next instance.")
            )
            ruledItem(
                title: String(localized: "Edit"),
                body: String(localized: "Tap anywhere on a task card (except the checkbox) to open the editor pre-filled with that task's details.")
            )
            ruledItem(
                title: String(localized: "Drag to reclassify"),
                body: String(localized: "Drag a task onto any other quadrant. An 8-point activation distance means plain taps still open the editor.")
            )
        }
    }

    // MARK: §6 cloud sync (optional)

    private var syncSection: some View {
        section(String(localized: "CLOUD SYNC (OPTIONAL)"), icon: "arrow.triangle.2.circlepath") {
            Text(String(localized: "Sync is off until you turn it on. In Settings, sign in with Google, Apple, or GitHub — once enabled, your tasks sync across your devices and the web app against a self-hosted backend."))
                .font(.callout)
                .foregroundStyle(Surface.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Text(String(localized: "A blue badge means there are pending changes to push; a red badge means the session expired and you need to sign in again. Manage the sync interval, see history, or turn sync off in Settings."))
                .font(.callout)
                .foregroundStyle(Surface.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: §7 privacy

    private var privacySection: some View {
        section(String(localized: "PRIVACY"), icon: "lock.shield") {
            Text(String(localized: "Your tasks live on this device. Nothing is sent to a server unless you explicitly sign in and enable sync. The app works fully offline — no account required."))
                .font(.callout)
                .foregroundStyle(Surface.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: footer

    private var footer: some View {
        Link(destination: URL(string: "https://gsdtaskmanager.com/")!) {
            Text(String(localized: "Read the About page →"))
                .font(.callout.weight(.medium))
                .foregroundStyle(Surface.tint)
        }
        .padding(.top, 4)
    }

    // MARK: building blocks

    /// An icon + uppercase eyebrow header above the section's content. `carded` wraps the
    /// content in the app's raised card (`surfaceCard`) so each topic reads as a contained
    /// panel — what turns a flowing article into a scannable help screen. The quadrant tiles
    /// opt out: they carry their own pigment washes, so a card around them would double the
    /// containment.
    private func section<Content: View>(
        _ title: String,
        icon: String,
        carded: Bool = true,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Surface.ink2)   // quiet glyph — tint stays reserved for actions
                Text(title)
                    .font(.caption.weight(.semibold))
                    .tracking(1.1)
                    .foregroundStyle(Surface.ink3)
            }
            if carded {
                VStack(alignment: .leading, spacing: 14) { content() }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .surfaceCard()
            } else {
                VStack(alignment: .leading, spacing: 10) { content() }
            }
        }
    }

    /// A serif sub-title + body paragraph behind a thin ink rule (the web's left border).
    private func ruledItem(title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Capsule()
                .fill(Surface.ink)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.serif(.title3).weight(.semibold))
                    .foregroundStyle(Surface.ink)
                Text(body)
                    .font(.callout)
                    .foregroundStyle(Surface.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// True where a hardware keyboard is realistic: Mac always; iPad yes; iPhone no.
    private var showsKeyboardShortcuts: Bool {
        #if targetEnvironment(macCatalyst)
        return true
        #else
        return UIDevice.current.userInterfaceIdiom == .pad
        #endif
    }
}

// MARK: - Rows

/// A pigment dot + serif quadrant name + one-line meaning.
private struct QuadrantGuideRow: View {
    let quadrant: Quadrant
    let blurb: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(QuadrantStyle.accent(quadrant))
                .frame(width: 10, height: 10)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(quadrant.title)
                    .font(.serif(.headline).weight(.semibold))
                    .foregroundStyle(Surface.ink)
                Text(blurb)
                    .font(.callout)
                    .foregroundStyle(Surface.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(QuadrantStyle.wash(quadrant), in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
    }
}

/// A monospace syntax token chip + its meaning.
private struct SyntaxRow: View {
    let token: String
    let meaning: String

    var body: some View {
        HStack(spacing: 12) {
            Text(token)
                .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                .foregroundStyle(Surface.ink)
                .frame(minWidth: 46)
                .padding(.vertical, 6)
                .background(Surface.sunken, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
            Text(meaning)
                .font(.subheadline)
                .foregroundStyle(Surface.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

/// One or more key-caps + what the shortcut does.
private struct ShortcutRow: View {
    let keys: [String]
    let label: String

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                ForEach(keys, id: \.self) { KeyCap(text: $0) }
            }
            .frame(width: 86, alignment: .leading)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(Surface.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

/// A single keyboard key rendered as a cap.
private struct KeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(.footnote, design: .monospaced).weight(.medium))
            .foregroundStyle(Surface.ink2)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(minWidth: 26)
            .background(Surface.sunken, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
                    .strokeBorder(Surface.hairline)
            )
    }
}
