import SwiftUI
import Charts
import GSDModel
import GSDStore

/// Analytics dashboard (product spec §6.15). A pure render of `store.analytics(trendDays:)`
/// — no computation here. The 7/30/90 segmented control only changes `trendDays`.
struct DashboardView: View {
    @Environment(TaskStore.self) private var store
    @Environment(PaletteController.self) private var palette
    @State private var trendDays = 7
    @State private var editor: EditorRequest?

    private var summary: AnalyticsSummary { store.analytics(trendDays: trendDays) }

    var body: some View {
        NavigationStack {
            Group {
                if summary.totalCount == 0 {
                    ContentUnavailableView(String(localized: "No data yet"), systemImage: "chart.bar.xaxis",
                                           description: Text(String(localized: "Add and complete tasks to see your insights here.")))
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            if summary.overdueCount > 0 { overdueBanner(summary.overdueCount) }
                            statGrid(summary)
                            trendSection(summary)
                            quadrantDonut(summary)
                            topTagsChart(summary)
                            timeByQuadrantChart(summary)
                            upcomingDeadlines(summary)
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle(String(localized: "Dashboard"))
            .toolbar { paletteButton(palette) }
            .sheet(item: $editor) { TaskEditorView(request: $0) }
        }
    }

    // MARK: sections

    private func overdueBanner(_ count: Int) -> some View {
        Label(String(localized: "\(count) overdue"), systemImage: "exclamationmark.triangle.fill")
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color.red, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityLabel(String(localized: "\(count) overdue tasks"))
    }

    private func statGrid(_ s: AnalyticsSummary) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            statCard(String(localized: "Active"), "\(s.activeCount)", "tray.full")
            statCard(String(localized: "Completed"), "\(s.completedCount)", "checkmark.circle")
            statCard(String(localized: "Completion"), "\(Int((s.completionRate * 100).rounded()))%", "percent")
            statCard(String(localized: "Streak"), String(localized: "\(s.activeStreak) days"), "flame")
            statCard(String(localized: "Best streak"), String(localized: "\(s.longestStreak) days"), "trophy")
            statCard(String(localized: "Tracked"), TimeTracking.format(minutes: s.totalTrackedMinutes), "clock")
        }
    }

    private func statCard(_ title: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.serif(.title2)).fontWeight(.semibold)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "\(title): \(value)"))
    }

    private func trendSection(_ s: AnalyticsSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(String(localized: "Completion Trend")).font(.headline)
                Spacer()
                Picker(String(localized: "Range"), selection: $trendDays) {
                    Text(String(localized: "7d")).tag(7)
                    Text(String(localized: "30d")).tag(30)
                    Text(String(localized: "90d")).tag(90)
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
            }
            Chart {
                ForEach(s.trend) { point in
                    LineMark(x: .value(String(localized: "Day"), point.date),
                             y: .value(String(localized: "Completed"), point.completed),
                             series: .value(String(localized: "Series"), String(localized: "Completed")))
                    .foregroundStyle(.green)
                    LineMark(x: .value(String(localized: "Day"), point.date),
                             y: .value(String(localized: "Created"), point.created),
                             series: .value(String(localized: "Series"), String(localized: "Created")))
                    .foregroundStyle(.blue)
                }
            }
            .frame(height: 200)
            .chartForegroundStyleScale([String(localized: "Completed"): Color.green,
                                        String(localized: "Created"): Color.blue])
            .accessibilityLabel(String(localized: "Completion trend over \(trendDays) days"))
        }
    }

    private func quadrantDonut(_ s: AnalyticsSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "By Quadrant")).font(.headline)
            Chart(s.quadrantStats.filter { $0.total > 0 }) { stat in
                SectorMark(angle: .value(String(localized: "Tasks"), stat.total), innerRadius: .ratio(0.6))
                    .foregroundStyle(by: .value(String(localized: "Quadrant"), stat.quadrant.title))
            }
            .frame(height: 220)
            .accessibilityLabel(String(localized: "Task distribution across the four quadrants"))
        }
    }

    private func topTagsChart(_ s: AnalyticsSummary) -> some View {
        Group {
            if s.topTags.isEmpty { EmptyView() } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(localized: "Top Tags")).font(.headline)
                    Chart(s.topTags) { stat in
                        BarMark(x: .value(String(localized: "Count"), stat.count),
                                y: .value(String(localized: "Tag"), stat.tag))
                    }
                    .frame(height: CGFloat(s.topTags.count) * 32 + 24)
                    .accessibilityLabel(String(localized: "Most-used tags by task count"))
                }
            }
        }
    }

    private func timeByQuadrantChart(_ s: AnalyticsSummary) -> some View {
        Group {
            if s.totalTrackedMinutes == 0 { EmptyView() } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(localized: "Time by Quadrant")).font(.headline)
                    Chart(s.timeByQuadrant) { stat in
                        BarMark(x: .value(String(localized: "Quadrant"), stat.quadrant.title),
                                y: .value(String(localized: "Minutes"), stat.minutes))
                        .foregroundStyle(by: .value(String(localized: "Quadrant"), stat.quadrant.title))
                    }
                    .frame(height: 200)
                    .accessibilityLabel(String(localized: "Tracked minutes per quadrant"))
                }
            }
        }
    }

    private func upcomingDeadlines(_ s: AnalyticsSummary) -> some View {
        Group {
            if s.upcomingDeadlines.isEmpty { EmptyView() } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(localized: "Upcoming Deadlines")).font(.headline)
                    ForEach(s.upcomingDeadlines) { task in
                        Button { editor = .edit(task) } label: {
                            HStack {
                                Text(task.title)
                                Spacer()
                                if let due = task.dueDate {
                                    Text(due, style: .date).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 6)
                        Divider()
                    }
                }
            }
        }
    }
}
