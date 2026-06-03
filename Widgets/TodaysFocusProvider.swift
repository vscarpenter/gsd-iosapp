import WidgetKit
import GSDSnapshot

/// Reads the precomputed snapshot. One entry, `.never` policy — `today-focus` has no time
/// component, so the app's `reloadAllTimelines()` is the sole refresh driver (spec §8).
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
        let entry = TodaysFocusEntry(date: Date(), snapshot: store.read() ?? .empty)
        completion(Timeline(entries: [entry], policy: .never))
    }
}
