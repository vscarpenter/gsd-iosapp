import WidgetKit
import GSDSnapshot

/// Reads the precomputed snapshot. The app's `reloadAllTimelines()` is the main refresh driver
/// (spec §8). The timeline also carries an entry for the next local midnight, because a widget
/// doesn't redraw by itself and today's picks must stop showing the moment the date changes
/// (spec-top-three section 9). `.atEnd` asks for a fresh timeline after that entry.
struct TodaysFocusProvider: TimelineProvider {
    private let store = WidgetSnapshotStore()

    func placeholder(in context: Context) -> TodaysFocusEntry {
        TodaysFocusEntry(date: Date(), snapshot: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (TodaysFocusEntry) -> Void) {
        let snapshot = context.isPreview ? .sample : (store.read() ?? .empty)
        completion(TodaysFocusEntry(date: Date(), snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodaysFocusEntry>) -> Void) {
        let now = Date()
        let snapshot = store.read() ?? .empty
        let midnight = WidgetSnapshot.nextLocalMidnight(after: now)
        completion(Timeline(entries: [TodaysFocusEntry(date: now, snapshot: snapshot),
                                      TodaysFocusEntry(date: midnight, snapshot: snapshot)],
                            policy: .atEnd))
    }
}
