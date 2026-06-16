import SwiftUI
import GSDModel
import GSDSnapshot

/// Mac-only menu-bar commands. Each item drives the SAME navigation the in-window
/// ⌘-shortcuts and deep links already use (DeepLinkHandoff → .gsdOpenDeepLink →
/// ContentView), so the menu bar reuses the app's routing instead of duplicating it.
struct GSDMenuCommands: Commands {
    var body: some Commands {
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
