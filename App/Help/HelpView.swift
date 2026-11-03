import SwiftUI
import GSDModel

/// The cross-platform "Field Guide" — a static reference sheet mirroring the web
/// help drawer (gsdtaskmanager.com). Shown from Settings ▸ About on every platform and
/// from the Mac Help menu (⌘?). Reads no `@Observable` env (pure content), so —
/// like `AboutView` — it needs no Catalyst re-injection. Presented as a sheet owned
/// by `ContentView` via the `.gsdShowHelp` notification.
struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    /// Whether the presenting root is compact. Passed in, as for the editor, because a sheet's
    /// own environment reads compact even on a full-width iPad.
    private let compactPresenter: Bool

    init(compactPresenter: Bool = false) {
        self.compactPresenter = compactPresenter
    }

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
                    dueDatesSection
                    escalationSection
                    gesturesSection
                    savedSection
                    morePlacesSection
                    syncSection
                    if showsKeyboardShortcuts { shortcutsSection }
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
                body: String(localized: "Your four quadrants are your home view: a 2×2 grid on iPad and Mac, four stacked sections on iPhone.")
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
            Text(String(localized: "Type into the capture bar. GSD reads priority markers as you type, and the chip at the end of the field shows which quadrant the task will land in. Tap the chip to pick a quadrant yourself."))
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

            Text(String(localized: "No marker files the task in Eliminate. Paste a link and GSD moves it into the task's notes. Tap Details to open the full editor with what you typed."))
                .font(.callout)
                .foregroundStyle(Surface.ink2)
                .fixedSize(horizontal: false, vertical: true)
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

    // MARK: due dates and reminders

    private var dueDatesSection: some View {
        section(String(localized: "DUE DATES & REMINDERS"), icon: "calendar") {
            Text(String(localized: "In the task editor, turn on Has due date, then pick Today, This week (Friday), or Next week (Monday), or choose a date. A due date is all day until you turn off All day and set a time."))
                .font(.callout)
                .foregroundStyle(Surface.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Text(String(localized: "A timed task reminds you before its due time, and all-day tasks remind you at 9 a.m. Each reminder has Complete and Snooze 1 hour buttons. When Quiet Hours is on in Settings › Notifications, reminders wait until the quiet window ends."))
                .font(.callout)
                .foregroundStyle(Surface.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: escalating

    private var escalationSection: some View {
        section(String(localized: "ESCALATING"), icon: "arrow.up") {
            Text(String(localized: "When a task that isn't marked urgent is due within two days (the default), or is overdue, its card says Escalating. Mark urgent moves it to Do First, or to Delegate if it isn't important. Find Mark urgent in the ⋯ menu, or swipe left on iPhone and iPad."))
                .font(.callout)
                .foregroundStyle(Surface.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Text(String(localized: "Nothing moves on its own. Change the window or turn it off in Settings › Appearance › Escalate tasks due within."))
                .font(.callout)
                .foregroundStyle(Surface.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: keyboard shortcuts (Mac and regular-width presenters)

    private var shortcutsSection: some View {
        section(String(localized: "KEYBOARD SHORTCUTS"), icon: "keyboard") {
            VStack(alignment: .leading, spacing: 10) {
                ShortcutRow(keys: ["⌘", "K"], label: String(localized: "Search tasks, views, and actions"))
                #if !targetEnvironment(macCatalyst)
                // The Mac binds nothing for ⌘F (ContentView.keyboardShortcuts), so the row is iOS-only.
                ShortcutRow(keys: ["⌘", "F"], label: String(localized: "Also opens search"))
                #endif
                ShortcutRow(keys: ["⌘", "N"], label: String(localized: "New task"))
                ShortcutRow(keys: ["⌘", "S"], label: String(localized: "Save the task you're editing"))
                ShortcutRow(keys: ["⌘", "1–4"], label: String(localized: "Jump to a quadrant"))
                ShortcutRow(keys: ["⌘", "?"], label: String(localized: "Open this field guide"))
                #if targetEnvironment(macCatalyst)
                ShortcutRow(keys: ["⌘", "R"], label: String(localized: "Sync now"))
                #endif
                ShortcutRow(keys: ["esc"], label: String(localized: "Close any sheet or drawer"))
            }
            Text(String(localized: "⌘S works from any field in the task editor, so you don't have to leave the field you're typing in."))
                .font(.footnote)
                .foregroundStyle(Surface.ink3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
    }

    // MARK: §5 working with a task (all platforms)

    private var gesturesSection: some View {
        section(String(localized: "WORKING WITH A TASK"), icon: "hand.draw") {
            ruledItem(
                title: String(localized: "Complete"),
                body: String(localized: "Tap the checkbox on any task card. Recurring tasks automatically spawn the next instance.")
            )
            ruledItem(
                title: String(localized: "Edit"),
                body: String(localized: "Tap anywhere on a task card (except the checkbox and ⋯) to open the editor pre-filled with that task's details.")
            )
            ruledItem(
                title: String(localized: "Swipe"),
                body: String(localized: "On iPhone and iPad, swipe right to complete. Swipe left to snooze for an hour or delete, or to Mark urgent when a task is escalating.")
            )
            ruledItem(
                title: String(localized: "The ⋯ menu"),
                body: String(localized: "The ⋯ button, or a long press, has the rest: Edit, Duplicate, Move to Saved, Share, Complete, the timer, Snooze, Move to, and Delete. On Mac, right-click a card for the same menu.")
            )
            ruledItem(
                title: String(localized: "Snooze"),
                body: String(localized: "Snooze reminds you again in 15 minutes, 30 minutes, 1 hour, 3 hours, a day (Tomorrow), or a week (Next week), and the card shows the time left. Clear a snooze in the editor.")
            )
            ruledItem(
                title: String(localized: "Move between quadrants"),
                body: String(localized: "On iPad and Mac, drag a card onto another quadrant. On iPhone, open the ⋯ menu and choose Move to.")
            )
            ruledItem(
                title: String(localized: "Undo and Trash"),
                body: String(localized: "After you delete a task, Undo shows for a few seconds. Deleted tasks stay in Settings › Trash for 30 days, where you can restore them or delete them for good.")
            )
        }
    }

    // MARK: saved

    private var savedSection: some View {
        section(String(localized: "SAVED"), icon: "bookmark") {
            Text(String(localized: "Saved keeps a task out of the matrix until you're ready for it, like an article to read or an idea. Choose Move to Saved from a task's ⋯ menu. Add notes, then choose Return to matrix to make it an active task again."))
                .font(.callout)
                .foregroundStyle(Surface.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Text(String(localized: "Saved items don't show in the matrix, smart views, or the dashboard, and they don't send reminders. Find Saved in Browse on iPhone, or under Library on iPad and Mac."))
                .font(.callout)
                .foregroundStyle(Surface.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: more places to look

    private var morePlacesSection: some View {
        section(String(localized: "MORE PLACES TO LOOK"), icon: "magnifyingglass") {
            ruledItem(
                title: String(localized: "Smart views"),
                body: String(localized: "Browse on iPhone, or the sidebar on iPad and Mac, lists nine built-in views and any you create. Pin up to five to keep them at the top.")
            )
            ruledItem(
                title: String(localized: "Archive"),
                body: String(localized: "Turn on Auto-archive completed tasks in Settings › Archive to move them out of the matrix after 30, 60, or 90 days, or choose Archive Now.")
            )
            ruledItem(
                title: String(localized: "Select several"),
                body: String(localized: "Choose Edit in the matrix toolbar to select tasks, then complete, move, tag, set a due date, or delete them together.")
            )
            ruledItem(
                title: String(localized: "Dashboard"),
                body: String(localized: "See your active and completed counts, your completion trend, tasks by quadrant, and tracked time.")
            )
            ruledItem(
                title: String(localized: "Timer"),
                body: String(localized: "Choose Start Timer from the ⋯ menu to track time on a task. The editor shows the time tracked against your estimate.")
            )
            ruledItem(
                title: String(localized: "Export and import"),
                body: String(localized: "Settings › Export saves a backup file. Import offers Merge, which keeps your tasks and adds the imported ones, or Replace, which deletes your current tasks first, on all your devices if you're signed in.")
            )
            ruledItem(
                title: String(localized: "Widget, Siri, and Shortcuts"),
                body: String(localized: "Add the Today's Focus widget to your Home Screen or desktop. Use Siri or Shortcuts to add a task, complete one, or open GSD.")
            )
            ruledItem(
                title: String(localized: "Share sheet and Spotlight"),
                body: String(localized: "In another app, share a link or some text and choose Add to GSD to capture it. Search for a task in Spotlight to open it in GSD.")
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
            Text(String(localized: "A number beside the sync icon counts changes waiting to upload. An amber icon needs attention, like being offline or a session that expired; tap it to open Settings and see why. A red icon means the last sync failed."))
                .font(.callout)
                .foregroundStyle(Surface.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Text(String(localized: "Pull down on the matrix to sync now, or press ⌘R on Mac. Settings › Account has Sync Now and Sync History. To stop syncing, sign out; your tasks stay on this device."))
                .font(.callout)
                .foregroundStyle(Surface.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: §7 privacy

    private var privacySection: some View {
        section(String(localized: "PRIVACY"), icon: "lock.shield") {
            Text(String(localized: "Your tasks live on this device. The app works fully offline — no account required. Sync is opt-in, and shared-link title fetching is a separate opt-in setting that requests only links you share. Feedback is sent only when you press Send Feedback."))
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

    /// True where a hardware keyboard is realistic: the Mac always, and any regular-width
    /// presenter (an iPad, an open iPhone Duo). The device idiom decided this before, which
    /// hid the section on the Duo's inner display: phone idiom, regular width.
    private var showsKeyboardShortcuts: Bool {
        #if targetEnvironment(macCatalyst)
        return true
        #else
        return !compactPresenter
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
