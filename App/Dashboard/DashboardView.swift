import SwiftUI
import Charts
import GSDModel
import GSDStore
import GSDSnapshot

/// Analytics dashboard (product spec §6.15). A pure render of `store.analytics(trendDays:)`
/// — no computation here. The 7/30/90 segmented control only changes `trendDays`.
/// Charts are re-skinned to the editorial palette: the four quadrant pigments, `success`
/// for completion, and graphite for the "created" baseline — no system blue/green.
struct DashboardView: View {
    @Environment(TaskStore.self) private var store
    @Environment(PaletteController.self) private var palette
    @Environment(SyncCoordinator.self) private var sync
    // Dashboard is shared: iPhone tab + iPad split-view detail. The chip is compact-only so
    // iPad doesn't show a second chip (the sidebar already has one) and the tap (Settings tab)
    // stays meaningful.
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var trendDays = 7
    @State private var editor: EditorRequest?

    private var summary: AnalyticsSummary { store.analytics(trendDays: trendDays) }

    /// Maps each quadrant's localized title → its accent, so Swift Charts colors
    /// sectors/bars with the four pigments instead of its default category palette.
    private var quadrantDomain: [String] { Quadrant.allCases.map(\.title) }
    private var quadrantRange: [Color] { Quadrant.allCases.map { QuadrantStyle.accent($0) } }

    var body: some View {
        NavigationStack {
            Group {
                if summary.totalCount == 0 {
                    DashboardEmptyState()
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            if summary.overdueCount > 0 { overdueBanner(summary.overdueCount) }
                            statGrid(summary)
                            trendSection(summary)
                            quadrantDonut(summary)
                            topTagsChart(summary)
                            timeByQuadrantChart(summary)
                            upcomingDeadlines(summary)
                        }
                        .padding(20)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Surface.paper)
            .navigationTitle(dashboardNavigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                brandedNavigationTitle(String(localized: "Dashboard"))
                paletteButton(palette)
                if sizeClass == .compact { syncStatusChip(sync, palette) }
            }
            .sheet(item: $editor) { TaskEditorView(request: $0).environment(store) }  // Catalyst: re-inject store across the sheet boundary
        }
    }

    private var dashboardNavigationTitle: String {
        #if targetEnvironment(macCatalyst)
        ""
        #else
        String(localized: "Dashboard")
        #endif
    }

    // MARK: sections

    /// Alert-wash card, not a filled block: the filled red banner was the loudest element
    /// in the app — off-brand for "the opposite of urgency-bait". Tapping it routes to the
    /// built-in Overdue Backlog smart view so the number is actionable, not just alarming.
    private func overdueBanner(_ count: Int) -> some View {
        Button {
            DeepLinkHandoff.open(.smartView("overdue"))
        } label: {
            HStack(spacing: 8) {
                Label(String(localized: "\(count) overdue"), systemImage: "exclamationmark.triangle")
                    .font(.headline)
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
            }
            .foregroundStyle(Surface.alert)
            .padding()
            .background(Surface.alertWash, in: RoundedRectangle(cornerRadius: Radius.input, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "\(count) overdue tasks"))
        .accessibilityHint(String(localized: "Shows the overdue backlog"))
    }

    /// Four honest workload stats. The Streak (flame) and Best-streak (trophy) tiles were
    /// removed by owner decision 2026-07-02: PRODUCT.md anti-references streaks/badges, and
    /// GSD measures progress without manufacturing reward.
    private func statGrid(_ s: AnalyticsSummary) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 11) {
            statCard(String(localized: "Active"), "\(s.activeCount)", "tray.full")
            statCard(String(localized: "Completed"), "\(s.completedCount)", "checkmark.circle")
            statCard(String(localized: "Completion"), "\(Int((s.completionRate * 100).rounded()))%", "percent")
            if s.totalTrackedMinutes == 0 {
                // Zero-state: "< 1m" read as cryptic data; an em-dash + spoken
                // "nothing tracked yet" is honest about the empty state.
                statCard(String(localized: "Tracked"), "—", "clock",
                         accessibilityValue: String(localized: "nothing tracked yet"))
            } else {
                statCard(String(localized: "Tracked"), TimeTracking.format(minutes: s.totalTrackedMinutes), "clock")
            }
        }
    }

    private func statCard(_ title: String, _ value: String, _ icon: String,
                          accessibilityValue: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.footnote).foregroundStyle(Surface.ink3)
                Text(title).font(.footnote).foregroundStyle(Surface.ink3)
            }
            Text(value).font(.serif(.title).weight(.semibold)).monospacedDigit()
                .foregroundStyle(Surface.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .surfaceCard(Radius.input)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "\(title): \(accessibilityValue ?? value)"))
    }

    private func trendSection(_ s: AnalyticsSummary) -> some View {
        let completed = String(localized: "Completed")
        let created = String(localized: "Created")
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(String(localized: "Completion Trend"))
                    .font(.serif(.title3).weight(.semibold)).foregroundStyle(Surface.ink)
                Spacer()
                Picker(String(localized: "Range"), selection: $trendDays) {
                    Text(String(localized: "7d")).tag(7)
                    Text(String(localized: "30d")).tag(30)
                    Text(String(localized: "90d")).tag(90)
                }
                .pickerStyle(.segmented)
                .frame(width: 170)
            }
            Chart {
                ForEach(s.trend) { point in
                    AreaMark(x: .value(String(localized: "Day"), point.date),
                             y: .value(completed, point.completed))
                        .foregroundStyle(Surface.success.opacity(0.08))
                    LineMark(x: .value(String(localized: "Day"), point.date),
                             y: .value(completed, point.completed),
                             series: .value(String(localized: "Series"), completed))
                        .foregroundStyle(Surface.success)
                        .lineStyle(StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                    LineMark(x: .value(String(localized: "Day"), point.date),
                             y: .value(created, point.created),
                             series: .value(String(localized: "Series"), created))
                        .foregroundStyle(Surface.ink3)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, dash: [2, 5]))   // 1.5pt dashes rendered near-invisible
                }
            }
            .chartForegroundStyleScale([completed: Surface.success, created: Surface.ink3])
            .chartXAxis { editorialAxis() }
            .chartYAxis { editorialAxis() }
            .frame(height: 200)
            .accessibilityLabel(String(localized: "Completion trend over \(trendDays) days"))
        }
        .padding(18)
        .surfaceCard()
    }

    /// Active tasks only: the donut's center KPI counts active tasks, so the slices (and
    /// legend) must chart the same population — mixing in completed tasks made the center
    /// read "10" over slices summing 24.
    private func quadrantDonut(_ s: AnalyticsSummary) -> some View {
        let stats = s.quadrantStats.filter { $0.active > 0 }
        return VStack(alignment: .leading, spacing: 14) {
            Text(String(localized: "Active by Quadrant"))
                .font(.serif(.title3).weight(.semibold)).foregroundStyle(Surface.ink)
            Chart(stats) { stat in
                SectorMark(angle: .value(String(localized: "Tasks"), stat.active), innerRadius: .ratio(0.62))
                    .foregroundStyle(by: .value(String(localized: "Quadrant"), stat.quadrant.title))
            }
            .chartForegroundStyleScale(domain: quadrantDomain, range: quadrantRange)
            .chartLegend(.hidden)
            .chartBackground { _ in
                VStack(spacing: 2) {
                    Text("\(s.activeCount)").font(.serif(.title).weight(.semibold)).monospacedDigit()
                        .foregroundStyle(Surface.ink)
                    Text(String(localized: "active")).font(.caption).foregroundStyle(Surface.ink3)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(height: 220)
            .accessibilityLabel(String(localized: "Active task distribution across the four quadrants"))

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(stats) { stat in
                    HStack(spacing: 9) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(QuadrantStyle.accent(stat.quadrant)).frame(width: 11, height: 11)
                        Text(stat.quadrant.title).font(.subheadline).foregroundStyle(Surface.ink2)
                        Spacer()
                        Text("\(stat.active)").font(.subheadline.weight(.semibold)).monospacedDigit()
                            .foregroundStyle(Surface.ink)
                    }
                }
            }
        }
        .padding(18)
        .surfaceCard()
    }

    private func topTagsChart(_ s: AnalyticsSummary) -> some View {
        Group {
            if s.topTags.isEmpty { EmptyView() } else {
                VStack(alignment: .leading, spacing: 14) {
                    Text(String(localized: "Top Tags"))
                        .font(.serif(.title3).weight(.semibold)).foregroundStyle(Surface.ink)
                    Chart(s.topTags) { stat in
                        BarMark(x: .value(String(localized: "Count"), stat.count),
                                y: .value(String(localized: "Tag"), stat.tag))
                            .foregroundStyle(Surface.ink3.opacity(0.82)) // graphite — a tag isn't a quadrant, so it doesn't borrow a pigment
                            .annotation(position: .trailing, alignment: .leading) {
                                Text("\(stat.count)").font(.footnote).monospacedDigit()
                                    .foregroundStyle(Surface.ink3)
                            }
                    }
                    .chartXAxis { editorialAxis() }
                    .chartYAxis { editorialAxis() }
                    .frame(height: CGFloat(s.topTags.count) * 32 + 24)
                    .accessibilityLabel(String(localized: "Most-used tags by task count"))
                }
                .padding(18)
                .surfaceCard()
            }
        }
    }

    private func timeByQuadrantChart(_ s: AnalyticsSummary) -> some View {
        Group {
            if s.totalTrackedMinutes == 0 { EmptyView() } else {
                VStack(alignment: .leading, spacing: 14) {
                    Text(String(localized: "Time by Quadrant"))
                        .font(.serif(.title3).weight(.semibold)).foregroundStyle(Surface.ink)
                    Chart(s.timeByQuadrant) { stat in
                        BarMark(x: .value(String(localized: "Quadrant"), stat.quadrant.title),
                                y: .value(String(localized: "Minutes"), stat.minutes))
                            .foregroundStyle(by: .value(String(localized: "Quadrant"), stat.quadrant.title))
                    }
                    .chartForegroundStyleScale(domain: quadrantDomain, range: quadrantRange)
                    .chartLegend(.hidden)
                    .chartXAxis { editorialAxis() }
                    .chartYAxis { editorialAxis() }
                    .frame(height: 200)
                    .accessibilityLabel(String(localized: "Tracked minutes per quadrant"))
                }
                .padding(18)
                .surfaceCard()
            }
        }
    }

    private func upcomingDeadlines(_ s: AnalyticsSummary) -> some View {
        Group {
            if s.upcomingDeadlines.isEmpty { EmptyView() } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "Upcoming Deadlines"))
                        .font(.serif(.title3).weight(.semibold)).foregroundStyle(Surface.ink)
                        .padding(.bottom, 8)
                    ForEach(Array(s.upcomingDeadlines.enumerated()), id: \.element.id) { index, task in
                        Button { editor = .edit(task) } label: {
                            HStack {
                                Text(task.title).foregroundStyle(Surface.ink)
                                Spacer()
                                if let due = task.dueDate {
                                    Text(due, style: .date)
                                        .foregroundStyle(due < .now ? Surface.alert : Surface.ink3)
                                        .fontWeight(due < .now ? .semibold : .regular)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 10)
                        if index < s.upcomingDeadlines.count - 1 {
                            Rectangle().fill(Surface.hairline).frame(height: 1)
                        }
                    }
                }
                .padding(18)
                .surfaceCard()
            }
        }
    }
}

/// Hairline gridlines + footnote ink-3 labels — the shared editorial axis treatment.
@AxisContentBuilder
private func editorialAxis() -> some AxisContent {
    AxisMarks { _ in
        AxisGridLine().foregroundStyle(Surface.hairline)
        AxisTick().foregroundStyle(Surface.hairline)
        AxisValueLabel().font(.footnote).foregroundStyle(Surface.ink3)
    }
}

/// Dashboard "no data" empty state (design §10): a quiet tile, serif headline, one line.
private struct DashboardEmptyState: View {
    var body: some View {
        EmptyStateView(
            icon: "chart.bar.xaxis",
            title: String(localized: "No stats yet"),
            message: String(localized: "Complete a few tasks and your trends will appear.")
        )
    }
}
