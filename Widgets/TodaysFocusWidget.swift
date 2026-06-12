import WidgetKit
import SwiftUI

struct TodaysFocusWidget: Widget {
    let kind = "TodaysFocusWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TodaysFocusProvider()) { entry in
            TodaysFocusView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName(String(localized: "Today's Focus"))
        .description(String(localized: "Your urgent and important tasks."))
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
