// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import UIKit
import ImageIO

/// 书库数据源：走 core 的 db 模块（SQLite 文件由 Swift 宿主提供）。
@MainActor
final class LibraryStore: ObservableObject {
    struct Book: Decodable, Identifiable, Equatable {
        struct Meta: Decodable, Equatable {
            let title: String?
            let author: String?
            let coverUrl: String?
        }

        let id: String
        let filePath: String
        let format: String?
        let meta: Meta
        let progress: Double?
        let currentCfi: String?
        var scrollResume: String? = nil
        let addedAt: Double?
        let lastOpenedAt: Double?

        var title: String { meta.title?.isEmpty == false ? meta.title! : "未命名" }
        var author: String { meta.author?.isEmpty == false ? meta.author! : "未知作者" }
        var progressValue: Double { progress ?? 0 }
        var coverRelativePath: String? { meta.coverUrl }
        var isEpub: Bool { (format ?? "epub").lowercased() == "epub" }
    }

    /// 语义检索命中的一段原文。
    struct SemanticHit: Decodable, Identifiable {
        let bookId: String
        let bookTitle: String
        let chapterIndex: Int
        let chapterTitle: String
        let content: String
        let score: Double

        var id: String { "\(bookId)-\(chapterIndex)-\(content.prefix(16))" }
        /// 回跳给阅读器的片段：一整段（chunk 里可能是多段拼的，取第一段就够定位）。
        var jumpText: String {
            content.split(separator: "\n").first.map(String.init) ?? content
        }
    }

    struct SemanticFailure: Decodable {
        let bookId: String
        let message: String
    }

    /// 已经建过语义索引的书。
    struct VectorizedBook: Decodable, Identifiable {
        let bookId: String
        let title: String
        let modelId: String
        let dimensions: Int
        let isVectorized: Bool

        var id: String { bookId }
    }

    /// 端侧向量模型信息（设置页显示）。
    struct EmbeddingInfo: Decodable {
        let available: Bool
        let modelId: String?
        let dimensions: Int?
        let error: String?
        let diagnostics: String?
        /// 只有英文词向量可用时（模拟器常见）：中文书建不了索引。
        let latinOnly: Bool?
    }

    private struct IndexStatus: Decodable {
        let status: String
        let bookId: String?
        let title: String?
        let progress: Double
        let chunks: Int
        let error: String?
    }

    enum SortField: String, CaseIterable, Identifiable {
        case lastOpened
        case added
        case title

        var id: String { rawValue }

        var label: String {
            switch self {
            case .lastOpened: "最近阅读"
            case .added: "最近添加"
            case .title: "书名"
            }
        }
    }

    enum ReadingFilter: String, CaseIterable, Identifiable {
        case all
        case reading
        case unread
        case finished

        var id: String { rawValue }

        var label: String {
            switch self {
            case .all: "全部"
            case .reading: "在读"
            case .unread: "未读"
            case .finished: "读完"
            }
        }
    }

    @Published private(set) var books: [Book] = []
    @Published private(set) var error: String?
    /// 非报错提示（例如「这本书已经在书库里，跳过重复导入」）。
    @Published private(set) var notice: String?
    @Published private(set) var isLoading = false
    @Published var sort: SortField = .lastOpened
    @Published var filter: ReadingFilter = .all
    @Published var query = ""
    /// 跨书语义检索的结果（边打字边搜，350ms 防抖）。
    @Published private(set) var semanticHits: [SemanticHit] = []
    @Published private(set) var semanticFailures: [SemanticFailure] = []
    @Published private(set) var isSearchingSemantics = false
    /// 已建索引的书，给书封上的标记和上下文菜单用。
    @Published private(set) var indexedBooks: [VectorizedBook] = []
    /// 正在建索引的书与进度（一本书一次）。
    @Published private(set) var indexingBookId: String?
    @Published private(set) var indexingProgress: Double = 0
    @Published private(set) var indexError: String?
    @Published private(set) var pendingIndexDeletion: Book?

    private let coverCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 32 * 1024 * 1024
        cache.countLimit = 200
        return cache
    }()
    private let coverQueue = DispatchQueue(label: "shudeng.covers", qos: .userInitiated)
    private var pendingCovers: Set<String> = []
    private var indexTimer: Timer?
    /// 建索引请求的代次：终态回调可能比下一次建索引更晚到达。
    private var indexGeneration = 0
    /// 语义检索的代次：打字快时旧结果不许覆盖新结果。
    private var searchGeneration = 0

    deinit {
        indexTimer?.invalidate()
    }

    /// 继续阅读：最近打开且没读完的书；没有在读书时不给卡片，避免出现「继续阅读 · 已读 0%」。
    var continueReading: Book? {
        books
            .filter { $0.progressValue > 0.001 && $0.progressValue < 0.999 }
            .max(by: { ($0.lastOpenedAt ?? 0) < ($1.lastOpenedAt ?? 0) })
    }

    var visibleBooks: [Book] {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return books
            .filter { book in
                switch filter {
                case .all: true
                case .reading: book.progressValue > 0.001 && book.progressValue < 0.999
                case .unread: book.progressValue <= 0.001
                case .finished: book.progressValue >= 0.999
                }
            }
            .filter { book in
                guard !keyword.isEmpty else { return true }
                return book.title.lowercased().contains(keyword) || book.author.lowercased().contains(keyword)
            }
            .sorted { left, right in
                switch sort {
                case .lastOpened: (left.lastOpenedAt ?? 0) > (right.lastOpenedAt ?? 0)
                case .added: (left.addedAt ?? 0) > (right.addedAt ?? 0)
                case .title: left.title.localizedStandardCompare(right.title) == .orderedAscending
                }
            }
    }

    func refresh(using runtime: RuntimeHost) {
        guard runtime.state == .ready else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let json = try runtime.appJSON("ShudengApp.listBooks()") ?? "[]"
            books = try JSONDecoder().decode([Book].self, from: Data(json.utf8))
            error = nil
        } catch {
            self.error = String(describing: error)
        }
        refreshIndex(using: runtime)
    }

    func isIndexed(_ book: Book) -> Bool {
        indexedBooks.contains { $0.bookId == book.id && $0.isVectorized }
    }

    func refreshIndex(using runtime: RuntimeHost) {
        guard runtime.state == .ready else { return }
        do {
            let json = try runtime.appJSON("ShudengApp.vectorizedBooks()", timeout: 60) ?? ""
            indexedBooks = try JSONDecoder().decode([VectorizedBook].self, from: Data(json.utf8))
            let available = Set(indexedBooks.filter(\.isVectorized).map(\.bookId))
            semanticHits.removeAll { !available.contains($0.bookId) }
            if indexError == "索引读取失败，已保留上次内容，请重试。" { indexError = nil }
        } catch {
            indexError = "索引读取失败，已保留上次内容，请重试。"
        }
    }

    func coverImage(for book: Book, root: URL) -> UIImage? {
        guard let relative = book.coverRelativePath, !relative.isEmpty else { return nil }
        if let cached = coverCache.object(forKey: relative as NSString) { return cached }
        guard pendingCovers.insert(relative).inserted else { return nil }
        let url = root.appendingPathComponent(relative)
        coverQueue.async { [weak self] in
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 768,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            let source = CGImageSourceCreateWithURL(url as CFURL, nil)
            let thumbnail = source.flatMap { CGImageSourceCreateThumbnailAtIndex($0, 0, options as CFDictionary) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.pendingCovers.remove(relative)
                guard let thumbnail else { return }
                self.objectWillChange.send()
                self.coverCache.setObject(UIImage(cgImage: thumbnail), forKey: relative as NSString,
                                          cost: thumbnail.bytesPerRow * thumbnail.height)
            }
        }
        return nil
    }

    // MARK: - 语义索引

    /// 建 / 重建一本书的语义索引：整本切块 + 端侧向量，进度靠轮询 vectorizeStatus。
    func buildIndex(for book: Book, using runtime: RuntimeHost) {
        guard runtime.state == .ready, indexingBookId == nil else { return }
        if pendingIndexDeletion?.id == book.id { pendingIndexDeletion = nil }
        indexGeneration += 1
        let generation = indexGeneration
        indexError = nil
        indexingBookId = book.id
        indexingProgress = 0
        startIndexPolling(using: runtime)
        runtime.callAsync("ShudengApp.vectorizeBook(\(Self.payload(["bookId": book.id])))", timeout: 900) {
            [weak self] json in
            guard let self, generation == self.indexGeneration else { return }
            if let message = Self.errorMessage(from: json) {
                self.indexError = "《\(book.title)》建索引失败：\(message)"
            }
            self.indexGeneration += 1
            self.indexingBookId = nil
            self.stopIndexPolling()
            self.refresh(using: runtime)
        }
    }

    func deleteIndex(for book: Book, using runtime: RuntimeHost) {
        guard runtime.state == .ready else { return }
        do {
            let json = try runtime.appJSON(
                "ShudengApp.deleteVectors(\(Self.payload(["bookId": book.id])))",
                timeout: 60
            ) ?? ""
            struct Receipt: Decodable { let ok: Bool }
            guard try JSONDecoder().decode(Receipt.self, from: Data(json.utf8)).ok else {
                throw NSError(domain: "IndexPersistence", code: 1)
            }
        } catch {
            pendingIndexDeletion = book
            // 删除前可能已经取消了后台建索引，失败后仍需同步任务状态。
            pollIndexStatus(using: runtime)
            refreshIndex(using: runtime)
            indexError = "《\(book.title)》索引删除未全部完成，请重试。"
            return
        }
        if indexingBookId == book.id {
            indexGeneration += 1
            indexingBookId = nil
            indexingProgress = 0
            stopIndexPolling()
        }
        if pendingIndexDeletion?.id == book.id { pendingIndexDeletion = nil }
        indexError = nil
        semanticHits = []
        refresh(using: runtime)
    }

    private func startIndexPolling(using runtime: RuntimeHost) {
        stopIndexPolling()
        let generation = indexGeneration
        let timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, generation == self.indexGeneration, self.indexingBookId != nil else { return }
                self.pollIndexStatus(using: runtime)
            }
        }
        indexTimer = timer
    }

    private func stopIndexPolling() {
        indexTimer?.invalidate()
        indexTimer = nil
    }

    private func pollIndexStatus(using runtime: RuntimeHost) {
        let json = runtime.appJSONOr("ShudengApp.vectorizeStatus()", fallback: "{}", timeout: 30)
        guard let status = try? JSONDecoder().decode(IndexStatus.self, from: Data(json.utf8)) else { return }
        switch status.status {
        case "idle":
            indexGeneration += 1
            indexingBookId = nil
            indexingProgress = 0
            stopIndexPolling()
        case "running":
            indexingBookId = status.bookId ?? indexingBookId
            indexingProgress = status.progress
        case "done":
            indexGeneration += 1
            indexingBookId = nil
            indexingProgress = 1
            stopIndexPolling()
            refresh(using: runtime)
        case "error":
            indexGeneration += 1
            indexingBookId = nil
            stopIndexPolling()
            if let message = status.error {
                indexError = "《\(status.title ?? "这本书")》建索引失败：\(message)"
            }
            refresh(using: runtime)
        default:
            break
        }
    }

    /// 跨书库语义检索。query 太短或没有建过索引的书就直接清空，不发请求。
    func searchSemantics(query text: String, using runtime: RuntimeHost) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        searchGeneration += 1
        let generation = searchGeneration
        guard runtime.state == .ready, trimmed.count >= 2, !indexedBooks.isEmpty else {
            isSearchingSemantics = false
            semanticHits = []
            semanticFailures = []
            return
        }
        isSearchingSemantics = true
        defer {
            if generation == searchGeneration { isSearchingSemantics = false }
        }

        struct Response: Decodable {
            let results: [SemanticHit]
            let errors: [SemanticFailure]
        }
        let json = await withCheckedContinuation { continuation in
            runtime.callAsync(
                "ShudengApp.semanticSearch(\(Self.payload(["query": trimmed, "topK": 6])))",
                timeout: 60
            ) { continuation.resume(returning: $0) }
        }
        guard generation == searchGeneration else { return }
        guard let response = try? JSONDecoder().decode(Response.self, from: Data(json.utf8)) else {
            semanticHits = []
            semanticFailures = []
            return
        }
        semanticHits = response.results
        semanticFailures = response.errors
    }

    static func embeddingInfo(using runtime: RuntimeHost) -> EmbeddingInfo? {
        let json = runtime.appJSONOr("ShudengApp.embeddingInfo()", fallback: "{}", timeout: 30)
        return try? JSONDecoder().decode(EmbeddingInfo.self, from: Data(json.utf8))
    }

    static func payload(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func errorMessage(from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = object["error"] as? String,
              !message.isEmpty
        else { return nil }
        return message
    }

    func delete(_ book: Book, using runtime: RuntimeHost) {
        guard runtime.state == .ready else { return }
        let payload = ["id": book.id]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        let json = String(decoding: data, as: UTF8.self)
        do {
            _ = try runtime.appJSON("ShudengApp.deleteBook(\(json))", timeout: 60)
            if pendingIndexDeletion?.id == book.id { pendingIndexDeletion = nil }
            let fileURL = runtime.rootDirectory.appendingPathComponent(book.filePath)
            try? FileManager.default.removeItem(at: fileURL)
            if let cover = book.coverRelativePath {
                try? FileManager.default.removeItem(at: runtime.rootDirectory.appendingPathComponent(cover))
            }
            if let cover = book.coverRelativePath { coverCache.removeObject(forKey: cover as NSString) }
            refresh(using: runtime)
        } catch {
            self.error = String(describing: error)
        }
    }

    func report(_ error: Error) {
        self.error = String(describing: error)
    }

    /// 导入：把选中的文件复制进 App 数据目录，再交给 core 抽元数据并落库。
    func importBook(from url: URL, using runtime: RuntimeHost) {
        guard runtime.state == .ready else { return }

        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        do {
            let ext = url.pathExtension.lowercased()
            let format = ext.isEmpty ? "epub" : ext
            let id = UUID().uuidString.lowercased()
            let relativePath = "books/\(id).\(format)"
            let destination = runtime.rootDirectory.appendingPathComponent(relativePath)

            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: url, to: destination)

            let payload: [String: String] = [
                "id": id,
                "path": relativePath,
                "fileName": url.lastPathComponent,
                "format": format,
            ]
            let json = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
            let raw = try runtime.appJSON("ShudengApp.importBook(\(json))", timeout: 120) ?? "{}"
            if let data = raw.data(using: .utf8),
               let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               result["duplicate"] as? Bool == true {
                // 重复导入：把刚复制进来的那份删掉，别白占空间。
                try? FileManager.default.removeItem(at: destination)
                let duplicateBook = result["book"] as? [String: Any]
                let duplicateMeta = duplicateBook?["meta"] as? [String: Any]
                let title = duplicateMeta?["title"] as? String
                notice = "《\(title?.isEmpty == false ? title! : url.lastPathComponent)》已经在书库里，已跳过重复导入"
                return
            }
            notice = nil
            error = nil
            refresh(using: runtime)
        } catch {
            self.error = String(describing: error)
        }
    }
}
