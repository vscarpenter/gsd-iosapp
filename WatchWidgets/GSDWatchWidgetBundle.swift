import WidgetKit
import SwiftUI

/// W3 declares the extension so the project, embedding, and signing are settled. W5 replaces this
/// placeholder with the Do First, inline, and Capture families (spec 4.5).
@main
struct GSDWatchWidgetBundle: WidgetBundle {
    var body: some Widget {
        AppGlyphWidget()
    }
}

private struct GlyphEntry: TimelineEntry { let date: Date }

private struct GlyphProvider: TimelineProvider {
    func placeholder(in context: Context) -> GlyphEntry { GlyphEntry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (GlyphEntry) -> Void) { completion(GlyphEntry(date: .now)) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<GlyphEntry>) -> Void) {
        completion(Timeline(entries: [GlyphEntry(date: .now)], policy: .never))
    }
}

private struct AppGlyphWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "GSDWatchGlyph", provider: GlyphProvider()) { _ in
            Image(systemName: "checkmark.circle")
                .accessibilityLabel("GSD")
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("GSD")
        .description("Open GSD.")
        .supportedFamilies([.accessoryCircular])
    }
}
