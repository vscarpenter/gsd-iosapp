import WidgetKit
import SwiftUI
import GSDModel
import GSDSnapshot

struct WatchWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: WatchSnapshot
}

/// Reads the snapshot the watch app saved. Entries: now, each due time left today, and the next
/// local midnight, then `.atEnd` (spec 4.5), so the inline line never shows yesterday's task.
struct WatchWidgetProvider: TimelineProvider {
    private var store: WatchSnapshotStore {
        WatchSnapshotStore(directoryURL: FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.id))
    }

    func placeholder(in context: Context) -> WatchWidgetEntry { WatchWidgetEntry(date: .now, snapshot: .empty) }

    func getSnapshot(in context: Context, completion: @escaping (WatchWidgetEntry) -> Void) {
        completion(WatchWidgetEntry(date: .now, snapshot: store.read() ?? .empty))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchWidgetEntry>) -> Void) {
        let snapshot = store.read() ?? .empty
        let dates = WatchWidgetContent.timelineDates(snapshot, now: .now, calendar: .current)
        completion(Timeline(entries: dates.map { WatchWidgetEntry(date: $0, snapshot: snapshot) }, policy: .atEnd))
    }

    /// Smart Stack relevance around the remaining due times. The older `date(from:to:)` form is
    /// deprecated in watchOS 26, so this uses `date(interval:kind:)`.
    func relevance() async -> WidgetRelevance<Void> {
        let snapshot = store.read() ?? .empty
        let windows = WatchWidgetContent.relevanceIntervals(snapshot, now: .now, calendar: .current)
        return WidgetRelevance(windows.map { WidgetRelevanceAttribute(context: .date(interval: $0, kind: .scheduled)) })
    }
}

struct GSDWatchWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "GSDWatchWidget", provider: WatchWidgetProvider()) { entry in
            GSDWatchWidgetView(entry: entry)
        }
        .configurationDisplayName("GSD")
        .description("Do First at a glance, and the next task due today.")
        .supportedFamilies([.accessoryRectangular, .accessoryInline, .accessoryCircular, .accessoryCorner])
    }
}

private struct GSDWatchWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WatchWidgetEntry

    var body: some View {
        switch family {
        case .accessoryRectangular: rectangular
        case .accessoryInline: inline
        default: glyph
        }
    }

    private var rectangular: some View {
        let titles = WatchWidgetContent.rectangularTitles(entry.snapshot, now: entry.date,
                                                          calendar: .current, timeZone: .current)
        return VStack(alignment: .leading, spacing: 2) {
            if titles.isEmpty {
                Text("Clear for now").font(.headline)
            } else {
                ForEach(titles, id: \.self) { Text($0).lineLimit(1) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(DeepLinkRoute.focus.url)
        .containerBackground(.fill.tertiary, for: .widget)
    }

    @ViewBuilder private var inline: some View {
        if let line = WatchWidgetContent.inline(entry.snapshot, now: entry.date, calendar: .current) {
            Text("\(line.time.formatted(date: .omitted, time: .shortened)) \(line.title)")
        } else {
            Text("GSD")
        }
    }

    /// No number: a count on a face reads as a nag. A tap opens Capture.
    private var glyph: some View {
        Image(systemName: "checkmark.circle")
            .accessibilityLabel("Add a task")
            .widgetURL(DeepLinkRoute.capture.url)
            .containerBackground(.fill.tertiary, for: .widget)
    }
}
