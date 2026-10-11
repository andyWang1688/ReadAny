// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct DailyPoint: Decodable, Identifiable {
    let date: String
    let totalTime: Double
    let pagesRead: Double
    let sessionsCount: Double

    var id: String { date }
}

struct PeriodMinutes: Decodable {
    let minutes: Double
    let pages: Double
}

struct OverallStats: Decodable {
    let totalBooks: Double
    let totalReadingTime: Double
    let totalSessions: Double
    let totalReadingDays: Double
    let avgDailyTime: Double
    let longestStreak: Double
    let currentStreak: Double
}

struct TopBookStat: Decodable, Identifiable {
    let bookId: String
    let title: String
    let author: String?
    let coverUrl: String?
    let totalTime: Double
    let progress: Double

    var id: String { bookId }
}

struct StatsPayload: Decodable {
    let days: Double
    let daily: [DailyPoint]
    let today: PeriodMinutes
    let week: PeriodMinutes
    let overall: OverallStats
    let topBooks: [TopBookStat]
    let bookCount: Double
    let readingNow: Double
}

@MainActor
final class StatsStore: ObservableObject {
    @Published private(set) var payload: StatsPayload?
    @Published private(set) var error: String?
    @Published private(set) var isLoading = false

    func refresh(using runtime: RuntimeHost, days: Int = 14) {
        guard runtime.state == .ready else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let json = try runtime.appJSON("ShudengApp.stats({ days: \(days) })", timeout: 60) ?? "{}"
            payload = try JSONDecoder().decode(StatsPayload.self, from: Data(json.utf8))
            error = nil
        } catch {
            self.error = String(describing: error)
        }
    }
}

struct StatsView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .largeTitle) private var todayNumberSize = 42
    @ScaledMetric(relativeTo: .caption2) private var chartDayWidth = 24
    @EnvironmentObject private var runtime: RuntimeHost
    @EnvironmentObject private var reading: ReadingSession
    @StateObject private var store = StatsStore()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let payload = store.payload {
                    todaySection(payload)
                    trendSection(payload)
                    entriesSection
                    if !payload.topBooks.isEmpty {
                        topBooksSection(payload)
                    }
                } else if let error = store.error {
                    EmptyHint(icon: "exclamationmark.triangle", title: "统计加载失败", message: error)
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40)
                }
            }
            .padding(.vertical, 16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("阅读统计")
        .navigationBarTitleDisplayMode(.inline)
        .task { store.refresh(using: runtime) }
        .onChange(of: runtime.state) { _, _ in store.refresh(using: runtime) }
        .onChange(of: reading.dataVersion) { _, _ in store.refresh(using: runtime) }
        .refreshable { store.refresh(using: runtime) }
    }

    private var rowLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 10))
    }

    /// 今天：一个大数字打头，底下三条小字用竖细线分开。
    /// 不再把「连续 / 最长 / 天数」拆成三张一样大的卡。
    private func todaySection(_ payload: StatsPayload) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                rowLayout {
                    Text("今天").font(.subheadline.weight(.semibold))
                    if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
                    Text(dateLabel())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                rowLayout {
                    HStack(alignment: .lastTextBaseline, spacing: 6) {
                        Text(minutesText(payload.today.minutes))
                            .font(.system(size: todayNumberSize, weight: .semibold))
                            .monospacedDigit()
                        Text("分钟").font(.subheadline).foregroundStyle(.secondary)
                    }
                    if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
                    if payload.today.pages > 0 {
                        Text("\(Int(payload.today.pages)) 页")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }

                Divider()

                rowLayout {
                    metric("本周", minutesText(payload.week.minutes), "分钟")
                    if !dynamicTypeSize.isAccessibilitySize { metricDivider }
                    metric("累计", hoursText(payload.overall.totalReadingTime), "小时")
                    if !dynamicTypeSize.isAccessibilitySize { metricDivider }
                    metric("连续", "\(Int(payload.overall.currentStreak))", "天")
                }
            }
        }
        .padding(.horizontal)
    }

    private func metric(_ title: String, _ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            HStack(alignment: .lastTextBaseline, spacing: 3) {
                Text(value).font(.headline).monospacedDigit()
                Text(unit).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var metricDivider: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(width: 0.5, height: 26)
            .padding(.horizontal, 12)
    }

    /// 最近 14 天：细柱子 + 一条基线；没读的日子只留一根贴底短刻度，
    /// 不再把 0 分钟画成和真实数据一样粗的灰条。
    private func trendSection(_ payload: StatsPayload) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                rowLayout {
                    Text("最近 \(payload.daily.count) 天").font(.subheadline.weight(.semibold))
                    if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
                    Text("平均 \(minutesText(payload.overall.avgDailyTime)) 分钟")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                let peak = max(payload.daily.map(\.totalTime).max() ?? 1, 1)
                if dynamicTypeSize.isAccessibilitySize {
                    ScrollView(.horizontal) { trendBars(payload, peak: peak) }
                } else {
                    trendBars(payload, peak: peak)
                }
                Text("峰值 \(minutesText(peak)) 分钟 · 共 \(Int(payload.overall.totalSessions)) 次阅读")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
    }

    private func trendBars(_ payload: StatsPayload, peak: Double) -> some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(payload.daily) { point in
                VStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(point.totalTime > 0 ? Color.primary : Color(.systemGray4).opacity(0.55))
                        .frame(width: 10, height: barHeight(point.totalTime, peak: peak, tallest: 104))
                    Text(dayLabel(point.date))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .frame(width: dynamicTypeSize.isAccessibilitySize ? chartDayWidth : nil)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(minHeight: 122, alignment: .bottom)
        .background(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
        }
    }

    /// 0 分钟的日子只留一根贴着基线的短刻度。
    private func barHeight(_ minutes: Double, peak: Double, tallest: CGFloat) -> CGFloat {
        guard minutes > 0 else { return 2 }
        return max(6, CGFloat(minutes / peak) * tallest)
    }

    /// 阅读报告和徽章是两行入口，跟系统设置里的分组行一个样子，不再各占一张卡。
    private var entriesSection: some View {
        VStack(spacing: 0) {
            NavigationLink {
                ReadingReportView()
            } label: {
                entryRow(title: "阅读报告", detail: "周 / 月 / 全部，还能让 AI 说两句")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("stats.report")

            Divider().padding(.leading, 16)

            BadgeSummaryRow()
        }
        .background(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .padding(.horizontal)
    }

    private func entryRow(title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline).foregroundStyle(Color(.label))
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    /// 书目排行：书名一行、进度一条，行与行之间用细线，不再每条都套一层容器。
    private func topBooksSection(_ payload: StatsPayload) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("书目排行").font(.subheadline.weight(.semibold))
                ForEach(Array(payload.topBooks.enumerated()), id: \.element.id) { index, book in
                    if index > 0 {
                        Divider()
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        rowLayout {
                            Text(book.title).font(.subheadline).lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
                            Text("\(minutesText(book.totalTime)) 分钟")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        if let author = book.author, !author.isEmpty {
                            Text(author).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        ThinProgressBar(value: book.progress)
                    }
                }
            }
        }
        .padding(.horizontal)
    }

    private func minutesText(_ minutes: Double) -> String {
        ReadingDuration.minutesValue(minutes)
    }

    private func hoursText(_ minutes: Double) -> String {
        let hours = minutes / 60
        if hours >= 10 { return String(Int(hours.rounded())) }
        return String(format: "%.1f", hours)
    }

    private func dateLabel() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M 月 d 日"
        return formatter.string(from: Date())
    }

    private func dayLabel(_ date: String) -> String {
        let parts = date.split(separator: "-")
        guard parts.count == 3 else { return "" }
        return "\(Int(parts[2]) ?? 0)"
    }
}
