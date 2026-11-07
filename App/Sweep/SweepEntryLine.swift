import SwiftUI
import GSDModel
import GSDStore

/// A quiet "Weekly sweep" line above the matrix while `WeeklySweep.entryShown` is true: at least
/// one card, and this device never swept or last swept seven or more local days ago. It shows no
/// count (the position line inside the sweep is the only count). It is always reachable from Settings.
struct SweepEntryLine: View {
    @Environment(TaskStore.self) private var store
    @Environment(\.escalationWindow) private var escalationWindow
    @State private var refresh = 0
    var action: () -> Void

    private var shown: Bool {
        _ = refresh
        let now = Date()
        let cards = WeeklySweep.cards(store.tasks, now: now, windowDays: escalationWindow.days, timeZone: .current)
        return WeeklySweep.entryShown(lastSweptAt: WeeklySweepSettings.lastSweptAt(),
                                      cardCount: cards.count, now: now, timeZone: .current)
    }

    var body: some View {
        Group {
            if shown {
                Button(action: action) {
                    HStack {
                        Label(String(localized: "Weekly sweep"), systemImage: "wind")
                            .font(.callout).foregroundStyle(Surface.ink2)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.footnote).foregroundStyle(Surface.ink3)
                            .accessibilityHidden(true)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .onAppear { refresh += 1 }   // re-read "last swept" when the sweep screen is popped
    }
}
