import SwiftUI
import WidgetKit
import GSDSnapshot

struct TodaysFocusView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TodaysFocusEntry

    private var visibleCount: Int { family == .systemSmall ? 3 : 5 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Today's Focus", systemImage: "target")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if entry.snapshot.tasks.isEmpty {
                Spacer(minLength: 0)
                Text("All clear")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                ForEach(entry.snapshot.tasks.prefix(visibleCount)) { task in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "circle").font(.caption2).foregroundStyle(.tint)
                        Text(task.title).font(.caption).lineLimit(1)
                    }
                }
                if entry.snapshot.totalCount > visibleCount {
                    Text("+\(entry.snapshot.totalCount - visibleCount) more")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(DeepLinkRoute.focus.url)
    }
}
