// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// 当前在阅读器里打开的书（书库点书 → 切到阅读 Tab）。
@MainActor
final class ReadingSession: ObservableObject {
    @Published var book: LibraryStore.Book? { didSet { handleBookChange(from: oldValue) } }
    /// 阅读器回传的当前页正文。
    @Published private(set) var visibleText = ""
    /// 阅读器回传的当前选区文字。
    @Published private(set) var selectionText = ""
    /// 当前选区 CFI（保存高亮用）。
    @Published private(set) var selectionCfi = ""
    /// 当前章节标题。
    @Published private(set) var chapterTitle = ""
    /// 当前章节正文（阅读器整章抽取，思维导图 / 技能当上下文用）。
    @Published private(set) var chapterText = ""
    /// 当前位置 CFI。
    @Published private(set) var cfi = ""
    /// 全书进度 0-1。
    @Published private(set) var fraction: Double = 0
    /// 阅读器是否正在全屏展示。
    @Published var isReaderPresented = false
    /// 从笔记跳进阅读器时要定位到的 CFI。
    @Published var pendingLocation: String?
    /// 语义检索结果回跳：索引里没有 cfi，给一段原文让阅读器自己搜。
    @Published var pendingSnippet: String?
    /// 数据版本号：阅读会话 / 高亮 / 笔记 / 书签落库后自增，书库和笔记页据此重新拉数据。
    @Published private(set) var dataVersion = 0
    /// 这本书已有的高亮文字：提问时一并喂给 AI，让它知道读者划过哪些句子。
    @Published private(set) var recentHighlights: [String] = []

    private(set) var sessionStartedAt: Date?
    private var pagesRead = 0
    private var charactersRead = 0
    private var startCfi = ""
    private var lastPageKey = ""
    /// 每页可见正文的字数：同一页重复回传时只记最大一次，避免重复累加。
    private var pageCharacters: [String: Int] = [:]
    /// 换书时要把上一本的会话落库，所以需要拿到运行时（由 RootView 注入）。
    private weak var runtime: RuntimeHost?

    func attach(to runtime: RuntimeHost) {
        self.runtime = runtime
    }

    /// 提问时喂给 AI 的上下文：位置 + 选区（没有选区就用当前页正文）+ 最近高亮。
    var promptContext: String {
        let selection = selectionText.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts: [String] = []

        var where_ = chapterTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if fraction > 0 {
            where_ = where_.isEmpty ? "进度 \(Int(fraction * 100))%" : "\(where_) · 进度 \(Int(fraction * 100))%"
        }
        if !where_.isEmpty { parts.append("当前位置：\(where_)") }

        if !selection.isEmpty {
            parts.append("选中原文：\n\(String(selection.prefix(2000)))")
        } else {
            let visible = visibleText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !visible.isEmpty { parts.append("当前页正文：\n\(String(visible.prefix(4000)))") }
        }

        let highlights = recentHighlights.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !highlights.isEmpty {
            let lines = highlights.suffix(10).map { "- \(String($0.prefix(200)))" }.joined(separator: "\n")
            parts.append("这本书里我之前划过的高亮：\n\(lines)")
        }

        return parts.joined(separator: "\n\n")
    }

    func setRecentHighlights(_ items: [String]) {
        guard items != recentHighlights else { return }
        recentHighlights = items
    }

    func setChapterText(_ text: String) {
        guard text != chapterText else { return }
        chapterText = text
    }

    var contextPreview: String {
        let text = promptContext.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
        return text.isEmpty ? "" : String(text.prefix(48))
    }

    func setVisibleText(_ text: String) {
        guard text != visibleText else { return }
        visibleText = text
        countVisibleCharacters(text)
    }

    /// 统计「读过多少字」：按 章节#页 去重，翻页回看不会重复计数。
    private func countVisibleCharacters(_ text: String) {
        let count = text.trimmingCharacters(in: .whitespacesAndNewlines).count
        guard count > 0 else { return }
        let key = lastPageKey.isEmpty ? "cfi:\(cfi)" : lastPageKey
        let previous = pageCharacters[key] ?? 0
        guard count > previous else { return }
        // 单次阅读上千页还没翻完的情况不存在，超过就停止累加，避免内存无上限。
        if previous == 0 && pageCharacters.count >= 5_000 { return }
        pageCharacters[key] = count
        charactersRead += count - previous
    }

    func setSelectionText(_ text: String) {
        selectionText = text
    }

    func setSelection(text: String, cfi: String) {
        selectionText = text
        selectionCfi = cfi
    }

    func updateProgress(fraction: Double, cfi: String, chapter: String, page: Int) {
        self.fraction = fraction
        if !cfi.isEmpty { self.cfi = cfi }
        if !chapter.isEmpty { chapterTitle = chapter }

        let key = "\(chapter)#\(page)"
        if !key.isEmpty, key != lastPageKey {
            if !lastPageKey.isEmpty { pagesRead += 1 }
            lastPageKey = key
        }
        if startCfi.isEmpty { startCfi = cfi }
    }

    func countReaderCharacters(_ count: Int) {
        charactersRead += max(0, count)
    }

    /// 打开一本书时开始计时。
    func beginSession() {
        sessionStartedAt = Date()
        pagesRead = 0
        charactersRead = 0
        pageCharacters.removeAll()
        startCfi = cfi
        lastPageKey = ""
    }

    /// 从后台回到前台时续上计时（切后台时已经落库并停了会话）。
    func resumeSession() {
        guard book != nil, isReaderPresented, sessionStartedAt == nil else { return }
        beginSession()
    }

    /// 高亮 / 笔记 / 书签写库后调用。
    func markDirty() {
        dataVersion &+= 1
    }

    /// 退出阅读器 / 切到后台 / 换书时落库：阅读会话 + 阅读进度。
    func flush(using runtime: RuntimeHost) {
        guard let book, let startedAt = sessionStartedAt else { return }
        flushSession(book: book, startedAt: startedAt, using: runtime)
    }

    private func flushSession(book: LibraryStore.Book, startedAt: Date, using runtime: RuntimeHost) {
        // 运行时没起来时先不结束本次计时，避免这段阅读时长被静默丢掉。
        guard runtime.state == .ready else { return }
        let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
        sessionStartedAt = nil

        let payload: [String: Any] = [
            "bookId": book.id,
            "startedAt": Int(startedAt.timeIntervalSince1970 * 1000),
            "totalActiveTime": elapsed,
            "pagesRead": max(pagesRead, 1),
            "charactersRead": charactersRead,
            "startCfi": startCfi,
            "endCfi": cfi,
        ]
        runtime.appJSONOr("ShudengApp.recordSession(\(json(payload)))", fallback: "\"skipped\"", timeout: 20)

        // 阅读器还没回报过位置（刚打开就退出 / 加载失败）时不动进度，
        // 否则会把已读位置刷成 0%（saveProgress 会把 progress 直接覆盖）。
        if !cfi.isEmpty {
            let progress: [String: Any] = [
                "bookId": book.id,
                "progress": fraction,
                "cfi": cfi,
            ]
            runtime.appJSONOr("ShudengApp.saveProgress(\(json(progress)))", timeout: 20)
        }

        pagesRead = 0
        charactersRead = 0
        pageCharacters.removeAll()
        markDirty()
    }

    private func json(_ value: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private func handleBookChange(from previous: LibraryStore.Book?) {
        // 从笔记 / 书签跳进另一本书时，上一本这次阅读的时长和进度不能丢。
        if let previous, previous.id != book?.id, let runtime, let startedAt = sessionStartedAt {
            flushSession(book: previous, startedAt: startedAt, using: runtime)
        }
        resetContext()
        lastPageKey = ""
        chapterTitle = ""
        cfi = ""
        fraction = 0
        if previous?.id != book?.id {
            sessionStartedAt = nil
        }
    }

    private func resetContext() {
        visibleText = ""
        selectionText = ""
        selectionCfi = ""
        chapterText = ""
    }
}
