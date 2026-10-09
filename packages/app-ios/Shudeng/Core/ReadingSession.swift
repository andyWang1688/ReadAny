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
    @Published private(set) var persistenceError: String?
    /// 这本书已有的高亮文字：提问时一并喂给 AI，让它知道读者划过哪些句子。
    @Published private(set) var recentHighlights: [String] = []

    private(set) var sessionStartedAt: Date?
    private var pagesRead = 0
    private var charactersRead = 0
    private var startCfi = ""
    private var lastPageKey = ""
    /// 每页可见正文的字数：同一页重复回传时只记最大一次，避免重复累加。
    private var pageCharacters: [String: Int] = [:]
    private struct SessionRecord: Codable {
        let id: String
        let bookId: String
        let startedAt: Int
        let totalActiveTime: Int
        let pagesRead: Int
        let charactersRead: Int
        let startCfi: String
        let endCfi: String
    }
    private struct ProgressRecord: Codable {
        let bookId: String
        let progress: Double
        let cfi: String
    }
    private struct PendingFlush: Codable {
        let record: SessionRecord
        let progress: ProgressRecord?
        var recordSaved = false
    }
    private enum SaveError: Error { case readQueue, writeQueue, database }
    private var pendingFlushes: [PendingFlush] = []
    private var queueLoaded = false
    private var isFlushing = false
    /// 换书时要把上一本的会话落库，所以需要拿到运行时（由 RootView 注入）。
    private weak var runtime: RuntimeHost?

    func attach(to runtime: RuntimeHost) {
        self.runtime = runtime
        flushPending(using: runtime)
    }

    func retryPersistence(using runtime: RuntimeHost) {
        flushPending(using: runtime)
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
        if text != visibleText { visibleText = text }
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
        if let runtime { flushPending(using: runtime) }
        guard book != nil, isReaderPresented, sessionStartedAt == nil else { return }
        beginSession()
    }

    /// 高亮 / 笔记 / 书签写库后调用。
    func markDirty() {
        dataVersion &+= 1
    }

    /// 退出阅读器 / 切到后台 / 换书时落库：阅读会话 + 阅读进度。
    func flush(using runtime: RuntimeHost) {
        if let book, let startedAt = sessionStartedAt {
            capturePending(book: book, startedAt: startedAt)
        }
        flushPending(using: runtime)
    }

    private func capturePending(book: LibraryStore.Book, startedAt: Date) {
        let record = SessionRecord(
            id: UUID().uuidString,
            bookId: book.id,
            startedAt: Int(startedAt.timeIntervalSince1970 * 1000),
            totalActiveTime: Int(Date().timeIntervalSince(startedAt) * 1000),
            pagesRead: max(pagesRead, 1),
            charactersRead: charactersRead,
            startCfi: startCfi,
            endCfi: cfi
        )
        let progress = cfi.isEmpty ? nil : ProgressRecord(bookId: book.id, progress: fraction, cfi: cfi)
        pendingFlushes.append(PendingFlush(record: record, progress: progress))
        sessionStartedAt = nil
        pagesRead = 0
        charactersRead = 0
        pageCharacters.removeAll()
    }

    private func queueURL(using runtime: RuntimeHost) -> URL {
        runtime.rootDirectory.appendingPathComponent("ReadingSession/pending-flushes.json")
    }

    private func loadPending(using runtime: RuntimeHost) throws {
        guard !queueLoaded else { return }
        let saved: [PendingFlush]
        do {
            let data = try Data(contentsOf: queueURL(using: runtime))
            saved = try JSONDecoder().decode([PendingFlush].self, from: data)
        } catch {
            let failure = error as NSError
            guard failure.domain == NSCocoaErrorDomain, failure.code == NSFileReadNoSuchFileError else {
                throw SaveError.readQueue
            }
            saved = []
        }
        // 先恢复旧队列，再追加 attach 前已经捕获的新会话，保持提交顺序。
        pendingFlushes = saved + pendingFlushes
        queueLoaded = true
    }

    private func persist(_ queue: [PendingFlush], using runtime: RuntimeHost) throws {
        do {
            let url = queueURL(using: runtime)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(queue).write(to: url, options: .atomic)
        } catch {
            throw SaveError.writeQueue
        }
    }

    private func expression<T: Encodable>(_ method: String, _ payload: T) throws -> String {
        let json = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
        return "ShudengApp.\(method)(\(json))"
    }

    private func flushPending(using runtime: RuntimeHost) {
        guard !isFlushing else { return }
        isFlushing = true
        defer { isFlushing = false }
        do {
            try loadPending(using: runtime)
            if !pendingFlushes.isEmpty { try persist(pendingFlushes, using: runtime) }
            guard runtime.state == .ready else {
                persistenceError = pendingFlushes.isEmpty ? nil : "阅读记录已暂存，内核就绪后会重试。"
                return
            }
            while let pending = pendingFlushes.first {
                if !pending.recordSaved {
                    let result = try runtime.appJSON(try expression("recordSession", pending.record), timeout: 20)
                    guard result == "ok" || result == "skipped" else { throw SaveError.database }
                    var acknowledged = pendingFlushes
                    acknowledged[0].recordSaved = true
                    try persist(acknowledged, using: runtime)
                    pendingFlushes = acknowledged
                }
                if let progress = pending.progress {
                    guard ["ok", "skipped"].contains(try runtime.appJSON(try expression("saveProgress", progress), timeout: 20)) else {
                        throw SaveError.database
                    }
                }
                let remaining = Array(pendingFlushes.dropFirst())
                try persist(remaining, using: runtime)
                pendingFlushes = remaining
                markDirty()
            }
            persistenceError = nil
        } catch SaveError.readQueue {
            persistenceError = "阅读暂存文件无法读取，已保留原文件，请重试。"
        } catch SaveError.writeQueue {
            persistenceError = "阅读记录无法暂存到本地，请检查存储空间后重试；退出应用可能丢失未暂存内容。"
        } catch {
            persistenceError = "阅读记录已暂存，数据库保存未完成，请重试。"
        }
    }

    private func handleBookChange(from previous: LibraryStore.Book?) {
        guard previous?.id != book?.id else { return }
        // 从笔记 / 书签跳进另一本书时，上一本这次阅读的时长和进度不能丢。
        if let previous, let startedAt = sessionStartedAt {
            capturePending(book: previous, startedAt: startedAt)
        }
        if let runtime { flushPending(using: runtime) }
        resetContext()
        lastPageKey = ""
        chapterTitle = ""
        cfi = ""
        fraction = 0
        sessionStartedAt = nil
    }

    private func resetContext() {
        visibleText = ""
        selectionText = ""
        selectionCfi = ""
        chapterText = ""
        recentHighlights.removeAll()
    }
}
