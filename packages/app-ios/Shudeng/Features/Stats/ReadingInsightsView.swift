// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

// MARK: - 徽章

struct BadgeItem: Decodable, Identifiable {
    let id: String
    let icon: String
    let tier: String
    let category: String
    let number: String
    let earned: Bool
    let title: String
    let desc: String

    var tierLabel: String {
        switch tier {
        case "bronze": "青铜"
        case "silver": "白银"
        case "gold": "黄金"
        case "platinum": "铂金"
        case "diamond": "钻石"
        case "legendary": "传奇"
        default: tier
        }
    }

    /// core 里的图标名是 lucide 风格，映射到 SF Symbols，认不出来时给个通用徽章。
    var symbol: String {
        switch icon {
        case "calendar": "calendar"
        case "flame": "flame"
        case "clock": "clock"
        case "library": "books.vertical"
        case "book-open": "book"
        case "pencil": "highlighter"
        case "brain": "brain.head.profile"
        case "moon": "moon.stars"
        case "sunrise": "sunrise"
        case "swords": "shield.lefthalf.filled"
        case "trophy": "trophy"
        default: "rosette"
        }
    }
}

struct BadgeCategory: Decodable, Identifiable {
    let key: String
    let title: String

    var id: String { key }
}

struct BadgesPayload: Decodable {
    let earned: Int
    let total: Int
    let categories: [BadgeCategory]
    let badges: [BadgeItem]
}

@MainActor
final class BadgeStore: ObservableObject {
    @Published private(set) var payload: BadgesPayload?
    @Published private(set) var error: String?

    func refresh(using runtime: RuntimeHost) {
        guard runtime.state == .ready else { return }
        let json = runtime.appJSONOr("ShudengApp.badges()", fallback: "", timeout: 60)
        guard !json.isEmpty,
              let payload = try? JSONDecoder().decode(BadgesPayload.self, from: Data(json.utf8))
        else {
            error = "徽章加载失败"
            return
        }
        self.payload = payload
        error = nil
    }
}

/// 统计页里的徽章入口：一行文字 + 最近拿到的几枚奖章，不再是三格大卡片。
struct BadgeSummaryRow: View {
    @EnvironmentObject private var runtime: RuntimeHost
    @EnvironmentObject private var reading: ReadingSession
    @StateObject private var store = BadgeStore()

    private var earnedBadges: [BadgeItem] {
        (store.payload?.badges ?? []).filter(\.earned)
    }

    var body: some View {
        NavigationLink {
            BadgesView(store: store)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("徽章").font(.subheadline).foregroundStyle(Color(.label))
                    Text(store.payload.map { "已获得 \($0.earned) / \($0.total)" } ?? "按阅读事实现算")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if !earnedBadges.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(earnedBadges.suffix(4)) { badge in
                            BadgeMedal(badge: badge, size: 22, dimmed: false)
                        }
                    }
                }
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("stats.badges")
        .task { store.refresh(using: runtime) }
        .onChange(of: runtime.state) { _, _ in store.refresh(using: runtime) }
        .onChange(of: reading.dataVersion) { _, _ in store.refresh(using: runtime) }
    }
}

struct BadgeMedal: View {
    let badge: BadgeItem
    var size: CGFloat = 44
    let dimmed: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(dimmed ? AnyShapeStyle(Color(.systemGray6)) : AnyShapeStyle(.tint))
            Image(systemName: badge.symbol)
                .font(.system(size: size * 0.42, weight: .medium))
                .foregroundStyle(dimmed ? Color.secondary : Color(.systemBackground))
        }
        .frame(width: size, height: size)
        .overlay(
            Circle().strokeBorder(Theme.hairline, lineWidth: 0.5)
        )
        .accessibilityLabel("\(badge.title)，\(badge.earned ? "已获得" : "未获得")")
    }
}

struct BadgesView: View {
    @EnvironmentObject private var runtime: RuntimeHost
    @ObservedObject var store: BadgeStore

    private let columns = [GridItem(.adaptive(minimum: 92), spacing: 12)]

    var body: some View {
        // 徽章页照 Apple Fitness 的奖章墙排：一格一枚奖章、名字压在下面，
        // 没拿到的只是灰掉，不再是一列带图标的清单。
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let payload = store.payload {
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .firstTextBaseline) {
                                Text("已获得 \(payload.earned) / \(payload.total)")
                                    .font(.headline)
                                    .monospacedDigit()
                                Spacer(minLength: 8)
                                Text("\(Int(Double(payload.earned) / Double(max(payload.total, 1)) * 100))%")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            ThinProgressBar(
                                value: Double(payload.earned) / Double(max(payload.total, 1)),
                                height: 5
                            )
                        }
                    }

                    ForEach(payload.categories) { category in
                        let items = payload.badges.filter { $0.category == category.key }
                        if !items.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("\(category.title) · \(items.filter(\.earned).count)/\(items.count)")
                                    .font(.subheadline.weight(.semibold))
                                LazyVGrid(columns: columns, spacing: 18) {
                                    ForEach(items) { badge in
                                        medalCell(badge)
                                    }
                                }
                            }
                        }
                    }

                    Text("徽章按每天的阅读事实实时计算，不占额外存储。")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else if let error = store.error {
                    EmptyHint(icon: "exclamationmark.triangle", title: "徽章加载失败", message: error)
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("徽章")
        .navigationBarTitleDisplayMode(.inline)
        .task { store.refresh(using: runtime) }
        .refreshable { store.refresh(using: runtime) }
    }

    private func medalCell(_ badge: BadgeItem) -> some View {
        VStack(spacing: 6) {
            BadgeMedal(badge: badge, size: 62, dimmed: !badge.earned)
            Text(badge.title)
                .font(.caption.weight(.medium))
                .foregroundStyle(badge.earned ? Color.primary : Color.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Text(badge.desc)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .accessibilityIdentifier("badge.\(badge.id)")
    }
}

// MARK: - 阅读报告

struct ReportPeriod: Decodable {
    let dimension: String
    let key: String
    let startDate: String
    let endDate: String
    let label: String
}

struct ReportSummary: Decodable {
    let totalReadingTime: Double
    let totalSessions: Double
    let totalPagesRead: Double
    let activeDays: Double
    let booksTouched: Double
    let completedBooks: Double
    let avgSessionTime: Double
    let longestSessionTime: Double
    let currentStreak: Double
    let longestStreak: Double
}

struct ReportTopBook: Decodable, Identifiable {
    let bookId: String
    let title: String
    let author: String
    let totalTime: Double
    let pagesRead: Double
    let progress: Double?

    var id: String { bookId }
}

struct ReportComparison: Decodable {
    let label: String
    let value: Double
    let delta: Double?
    let deltaLabel: String
}

struct ReportPayload: Decodable {
    let dimension: String
    let period: ReportPeriod
    let summary: ReportSummary
    let topBooks: [ReportTopBook]
    let previous: [ReportComparison]
}

enum ReadingReportRange: String, CaseIterable, Identifiable {
    case week
    case month
    case lifetime

    var id: String { rawValue }

    var label: String {
        switch self {
        case .week: "本周"
        case .month: "本月"
        case .lifetime: "全部"
        }
    }

    /// 给模型的抬头，比 core 的英文 label 更像中文人话。
    var aiLabel: String {
        switch self {
        case .week: "最近一周"
        case .month: "最近一个月"
        case .lifetime: "有记录以来"
        }
    }
}

@MainActor
final class ReportStore: ObservableObject {
    @Published private(set) var payload: ReportPayload?
    @Published private(set) var error: String?
    @Published private(set) var isLoading = false

    func refresh(using runtime: RuntimeHost, range: ReadingReportRange) {
        guard runtime.state == .ready else { return }
        isLoading = true
        defer { isLoading = false }
        let json = runtime.appJSONOr(
            "ShudengApp.report({ period: \"\(range.rawValue)\" })",
            fallback: "",
            timeout: 60
        )
        guard !json.isEmpty,
              let payload = try? JSONDecoder().decode(ReportPayload.self, from: Data(json.utf8))
        else {
            error = "报告加载失败"
            self.payload = nil
            return
        }
        self.payload = payload
        error = nil
    }
}

struct ReadingReportView: View {
    @EnvironmentObject private var runtime: RuntimeHost
    @EnvironmentObject private var reading: ReadingSession
    @EnvironmentObject private var aiSettings: AISettings
    @StateObject private var store = ReportStore()

    @State private var range: ReadingReportRange = .week
    @State private var aiText: [ReadingReportRange: String] = [:]
    @State private var aiError: String?
    @State private var isGenerating = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Picker("区间", selection: $range) {
                    ForEach(ReadingReportRange.allCases) { item in
                        Text(item.label).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal)
                .accessibilityIdentifier("report.range")

                if let payload = store.payload {
                    periodLine(payload)
                    if payload.summary.totalReadingTime > 0 {
                        metricsCard(payload)
                        statusRows(payload)
                        if !payload.topBooks.isEmpty { topBooksCard(payload) }
                        aiCard(payload)
                    } else {
                        EmptyHint(
                            icon: "book.closed",
                            title: "这一段时间还没有阅读记录",
                            message: range == .lifetime ? "读上几分钟再回来看" : "换个区间或先读一会儿"
                        )
                    }
                } else if let error = store.error {
                    EmptyHint(icon: "exclamationmark.triangle", title: "报告加载失败", message: error)
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40)
                }
            }
            .padding(.vertical)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("阅读报告")
        .navigationBarTitleDisplayMode(.inline)
        .task { store.refresh(using: runtime, range: range) }
        .onChange(of: range) { _, newValue in
            aiError = nil
            store.refresh(using: runtime, range: newValue)
        }
        .refreshable { store.refresh(using: runtime, range: range) }
    }

    /// 期间名和日期说的是同一件事，只留一行日期。
    private func periodLine(_ payload: ReportPayload) -> some View {
        Text(periodRangeText(payload))
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .padding(.horizontal)
    }

    /// 本期数字排成三列网格，不做成一格一张卡。
    private func metricsCard(_ payload: ReportPayload) -> some View {
        let summary = payload.summary
        let numbers: [(value: String, label: String)] = [
            ("\(Int(summary.totalReadingTime))", "分钟"),
            ("\(Int(summary.activeDays))", "有阅读的天数"),
            ("\(Int(summary.totalPagesRead))", "翻过 · 页"),
            ("\(Int(summary.booksTouched))", "读过 · 本"),
            ("\(Int(summary.completedBooks))", "读完 · 本"),
            ("\(Int(summary.longestSessionTime))", "最长单次 · 分钟"),
        ]
        return VStack(alignment: .leading, spacing: 6) {
            SectionHeader("本期数字")
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3),
                alignment: .leading,
                spacing: 0
            ) {
                ForEach(Array(numbers.enumerated()), id: \.offset) { index, item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.value)
                            .font(.system(size: 19, weight: .semibold))
                            .monospacedDigit()
                        Text(item.label)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: numberAlignment(index))
                    .padding(.vertical, 10)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(Theme.hairline).frame(height: 0.5)
                    }
                }
            }
        }
        .padding(.horizontal)
    }

    private func numberAlignment(_ index: Int) -> Alignment {
        switch index % 3 {
        case 1: .center
        case 2: .trailing
        default: .leading
        }
    }

    /// 环比和 AI 入口各占一行，不做成卡片。
    private func statusRows(_ payload: ReportPayload) -> some View {
        VStack(spacing: 0) {
            if let row = payload.previous.first {
                HStack(spacing: 10) {
                    Text("和上一期比")
                        .font(.subheadline)
                    Spacer(minLength: 8)
                    Text("\(row.label) \(deltaText(row))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                Divider()
            }
            aiEntryRow(payload)
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .padding(.horizontal)
    }

    private func aiEntryRow(_ payload: ReportPayload) -> some View {
        HStack(spacing: 10) {
            Text("AI 解读")
                .font(.subheadline)
            Spacer(minLength: 8)
            if let text = aiText[range], !text.isEmpty {
                Button("重新生成") { generate(payload) }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .disabled(isGenerating)
                    .accessibilityIdentifier("report.aiRegenerate")
            } else if isGenerating {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("正在生成…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Button {
                    generate(payload)
                } label: {
                    HStack(spacing: 3) {
                        Text("让 AI 说两句")
                        Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
                    }
                    .font(.footnote)
                }
                .foregroundStyle(.tint)
                .disabled(!aiSettings.isConfigured)
                .accessibilityIdentifier("report.ai")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func topBooksCard(_ payload: ReportPayload) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader("这段时间读的书")
                ForEach(payload.topBooks) { book in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(book.title).font(.subheadline).lineLimit(1)
                            Spacer(minLength: 8)
                            Text("\(Int(book.totalTime)) 分钟")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        if let progress = book.progress, progress > 0 {
                            ThinProgressBar(value: progress)
                        }
                    }
                }
            }
        }
        .padding(.horizontal)
    }

    private func aiCard(_ payload: ReportPayload) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let text = aiText[range], !text.isEmpty {
                MarkdownText(text: text)
            } else if !isGenerating, !aiSettings.isConfigured {
                Text("先在「我的 → AI 设置」里填端点和模型")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let aiError {
                Text(aiError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
    }

    private func generate(_ payload: ReportPayload) {
        guard aiSettings.isConfigured else {
            aiError = "先在「我的 → AI 设置」里填端点和模型"
            return
        }
        isGenerating = true
        aiError = nil
        let current = range

        let body = [
            "system": "你是一位简洁、真诚的中文阅读教练。只输出解读正文，不要寒暄，不要复述我给的全部数字。",
            "text": aiPrompt(payload),
            "provider": aiSettings.provider.rawValue,
            "apiKey": aiSettings.apiKey,
            "baseUrl": aiSettings.baseURL,
            "model": aiSettings.model,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        let json = String(decoding: data, as: UTF8.self)

        runtime.callAsync("ShudengApp.aiReport(\(json))", timeout: 120) { result in
            isGenerating = false
            guard let resultData = result.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any]
            else {
                if range == current { aiError = "解读失败：返回内容看不懂" }
                return
            }
            if let error = object["error"] as? String, !error.isEmpty {
                if range == current { aiError = "解读失败：\(error)" }
                return
            }
            let text = (object["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                if range == current { aiError = "解读失败：模型没有返回内容" }
                return
            }
            aiText[current] = text
        }
    }

    /// 只把模型真正需要的数字给它，顺手把单位写清楚，中文提示词比英文稳。
    private func aiPrompt(_ payload: ReportPayload) -> String {
        let summary = payload.summary
        var lines: [String] = [
            "周期：\(range.aiLabel)（\(payload.period.startDate) 到 \(payload.period.endDate)）",
            "阅读时长：\(durationText(summary.totalReadingTime))",
            "有阅读的天数：\(Int(summary.activeDays)) 天",
            "总页数：\(Int(summary.totalPagesRead)) 页",
            "读过：\(Int(summary.booksTouched)) 本，读完：\(Int(summary.completedBooks)) 本",
            "阅读次数：\(Int(summary.totalSessions)) 次，平均每次 \(Int(summary.avgSessionTime)) 分钟，最长一次 \(Int(summary.longestSessionTime)) 分钟",
            "最长连续阅读：\(Int(summary.longestStreak)) 天，当前连续：\(Int(summary.currentStreak)) 天",
        ]
        if !payload.topBooks.isEmpty {
            let books = payload.topBooks.map { "\($0.title)（\(Int($0.totalTime)) 分钟）" }.joined(separator: "、")
            lines.append("读得最多的书：\(books)")
        }
        if !payload.previous.isEmpty {
            let rows = payload.previous.map { "\($0.label) \(Int($0.value))（\(deltaText($0))）" }.joined(separator: "；")
            lines.append("与上一期对比：\(rows)")
        }
        return """
        请根据下面的阅读数据写一段 150 字以内的解读：先肯定做得好的地方，再指出一个可以改进的点，最后给一条具体可执行的建议。

        \(lines.joined(separator: "\n"))
        """
    }

    private func durationText(_ minutes: Double) -> String {
        if minutes >= 60 {
            return String(format: "%.1f 小时", minutes / 60)
        }
        return "\(Int(minutes.rounded())) 分钟"
    }

    private func deltaText(_ row: ReportComparison) -> String {
        guard let delta = row.delta else { return row.deltaLabel.isEmpty ? "—" : row.deltaLabel }
        if abs(delta) < 0.5 { return "持平" }
        let arrow = delta > 0 ? "↑" : "↓"
        return "\(arrow)\(Int(abs(delta).rounded()))"
    }

    /// 同一年只写一次年份，日期区间一眼能读完。
    private func periodRangeText(_ payload: ReportPayload) -> String {
        let start = payload.period.startDate
        let end = payload.period.endDate
        guard start.count == 10, end.count == 10 else { return "\(start) – \(end)" }
        return start.prefix(4) == end.prefix(4)
            ? "\(start) – \(end.suffix(5))"
            : "\(start) – \(end)"
    }
}
