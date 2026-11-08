import WidgetKit
import SwiftUI
import GSDModel
import GSDSnapshot

struct WatchWidgetEntry: TimelineEntry {
    let date: Date
    /// `nil` until the phone's first snapshot reaches the watch.
    let snapshot: WatchSnapshot?
}

/// Reads the snapshot the watch app saved. Entries: now, each due time left today, and the next
/// local midnight, then `.atEnd` (spec 4.5), so the inline line never shows yesterday's task.
struct WatchWidgetProvider: TimelineProvider {
    private var store: WatchSnapshotStore {
        WatchSnapshotStore(directoryURL: FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.id))
    }

    /// A sample row, so the gallery shows what the widget looks like instead of the empty state.
    func placeholder(in context: Context) -> WatchWidgetEntry {
        let sample = WatchTask(id: "sample", title: "Call the dentist", urgent: true, important: true,
                               createdAt: .now, updatedAt: .now, isRecurring: false)
        return WatchWidgetEntry(date: .now, snapshot: WatchSnapshot(
            generatedAt: .now, escalationWindowDays: nil, tasks: [sample], doFirstTotal: 1, appliedCommandIDs: []))
    }

    func getSnapshot(in context: Context, completion: @escaping (WatchWidgetEntry) -> Void) {
        completion(WatchWidgetEntry(date: .now, snapshot: store.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchWidgetEntry>) -> Void) {
        let snapshot = store.read()
        let dates = WatchWidgetContent.timelineDates(snapshot ?? .empty, now: .now, calendar: .current)
        completion(Timeline(entries: dates.map { WatchWidgetEntry(date: $0, snapshot: snapshot) }, policy: .atEnd))
    }

    /// Smart Stack relevance around the remaining due times. The older `date(from:to:)` form is
    /// deprecated in watchOS 26, so this uses `date(interval:kind:)`.
    func relevance() async -> WidgetRelevance<Void> {
        let windows = WatchWidgetContent.relevanceIntervals(store.read() ?? .empty, now: .now, calendar: .current)
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
        let content = WatchWidgetContent.rectangular(entry.snapshot, now: entry.date,
                                                     calendar: .current, timeZone: .current)
        return VStack(alignment: .leading, spacing: 2) {
            switch content {
            case .needsPhone:
                Text("Open GSD on your iPhone to load your tasks.").font(.footnote)
            case .clear:
                Text("Clear for now").font(.headline)
            case .rows(let titles):
                ForEach(titles, id: \.self) { Text($0).lineLimit(1) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(DeepLinkRoute.focus.url)
        .containerBackground(.fill.tertiary, for: .widget)
    }

    @ViewBuilder private var inline: some View {
        if let snapshot = entry.snapshot,
           let line = WatchWidgetContent.inline(snapshot, now: entry.date, calendar: .current) {
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
