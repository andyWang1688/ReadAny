// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct HighlightItem: Decodable, Identifiable {
    let id: String
    let bookId: String
    let cfi: String
    let text: String
    let color: String
    let note: String?
    let chapterTitle: String?
    let createdAt: Double
    let bookTitle: String?
    let bookAuthor: String?
    let bookCoverUrl: String?

    var colorValue: Color {
        switch color {
        case "green": Color(hex: "#4ade80")
        case "blue": Color(hex: "#60a5fa")
        case "pink": Color(hex: "#f472b6")
        case "purple": Color(hex: "#c084fc")
        case "red": Color(hex: "#f87171")
        default: Color(hex: "#facc15")
        }
    }
}

struct BookmarkItem: Decodable, Identifiable {
    let id: String
    let bookId: String
    let cfi: String
    let label: String?
    let chapterTitle: String?
    let createdAt: Double
}

/// 导出到临时目录后的分享载荷。
struct NotesExport: Identifiable {
    let id = UUID()
    let url: URL
    let label: String
}

@MainActor
final class NotesStore: ObservableObject {
    @Published private(set) var highlights: [HighlightItem] = []
    @Published private(set) var bookmarks: [BookmarkItem] = []
    @Published private(set) var error: String?

    func refresh(using runtime: RuntimeHost) {
        guard runtime.state == .ready else { return }
        do {
            let highlightJSON = try runtime.appJSON("ShudengApp.listHighlights({})", timeout: 60) ?? ""
            highlights = try JSONDecoder().decode([HighlightItem].self, from: Data(highlightJSON.utf8))
            error = nil
        } catch {
            self.error = "笔记读取失败，已保留上次内容，请重试。"
        }
    }

    /// 不带 bookId 一次性拿全部书签，避免按书循环调用把主线程堵住。
    func refreshBookmarks(using runtime: RuntimeHost) {
        guard runtime.state == .ready else { return }
        do {
            let text = try runtime.appJSON("ShudengApp.listBookmarks({})", timeout: 60) ?? ""
            let items = try JSONDecoder().decode([BookmarkItem].self, from: Data(text.utf8))
            bookmarks = items.sorted { $0.createdAt > $1.createdAt }
        } catch {
            self.error = "书签读取失败，已保留上次内容，请重试。"
        }
    }

    func delete(highlight: HighlightItem, using runtime: RuntimeHost) {
        let payload: [String: Any] = ["id": highlight.id]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        let json = String(decoding: data, as: UTF8.self)
        guard write("ShudengApp.deleteHighlight(\(json))", using: runtime) else { return }
        highlights.removeAll { $0.id == highlight.id }
    }

    func delete(bookmark: BookmarkItem, using runtime: RuntimeHost) {
        let payload: [String: Any] = ["id": bookmark.id]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        let json = String(decoding: data, as: UTF8.self)
        guard write("ShudengApp.deleteBookmark(\(json))", using: runtime) else { return }
        bookmarks.removeAll { $0.id == bookmark.id }
    }

    @discardableResult
    func update(highlight: HighlightItem, note: String, using runtime: RuntimeHost) -> Bool {
        let payload: [String: Any] = ["id": highlight.id, "note": note]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return false }
        let json = String(decoding: data, as: UTF8.self)
        guard write("ShudengApp.updateHighlight(\(json))", using: runtime) else { return false }
        refresh(using: runtime)
        return true
    }

    private func write(_ expression: String, using runtime: RuntimeHost) -> Bool {
        do {
            guard try runtime.appJSON(expression, timeout: 30) == "ok" else {
                throw NSError(domain: "NotesPersistence", code: 1)
            }
            error = nil
            return true
        } catch {
            self.error = "操作没能保存到本地，请检查存储空间后重试。"
            return false
        }
    }
}

struct NotesView: View {
    @EnvironmentObject private var runtime: RuntimeHost
    @EnvironmentObject private var reading: ReadingSession
    @StateObject private var store = NotesStore()
    @StateObject private var library = LibraryStore()
    @State private var mode: Mode = .highlights
    @State private var editing: HighlightItem?
    @State private var noteDraft = ""
    @State private var share: NotesExport?
    @State private var exportError: String?
    @State private var searchText = ""

    enum Mode: String, CaseIterable, Identifiable {
        case highlights
        case notes
        case bookmarks

        var id: String { rawValue }

        var label: String {
            switch self {
            case .highlights: "高亮"
            case .notes: "笔记"
            case .bookmarks: "书签"
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases) { item in
                        Text(item.label).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)

                if let error = store.error {
                    HStack {
                        Text(error).font(.footnote)
                        Spacer()
                        Button("重试读取") { reload() }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                    .accessibilityIdentifier("notes.error")
                }

                Group {
                    if runtime.state != .ready {
                        EmptyLine(text: "书灯内核正在启动，稍等一下。")
                    } else if mode == .bookmarks {
                        if visibleBookmarks.isEmpty {
                            EmptyLine(text: "读到一半想标记，点书签按钮，就会收在这里。")
                        } else {
                            bookmarkList
                        }
                    } else if visibleItems.isEmpty {
                        EmptyLine(
                            text: !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? "没有找到匹配的内容"
                                : mode == .highlights
                                ? "阅读时选中一句话，就能留下高亮和想法。"
                                : "写下想法的笔记，都会收在这里。"
                        )
                    } else {
                        list
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .searchable(text: $searchText, prompt: "搜索高亮、笔记或书名")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("导出 Markdown", systemImage: "doc.text") { export(.markdown) }
                        Button("导出 HTML", systemImage: "safari") { export(.html) }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("notes.export")
                    .accessibilityLabel("导出")
                    .disabled(store.highlights.isEmpty && store.bookmarks.isEmpty)
                }
            }
            .task {
                reload()
            }
            .onChange(of: runtime.state) { _, _ in
                reload()
            }
            .onChange(of: mode) { _, _ in
                if mode == .bookmarks { reload() }
            }
            .onChange(of: reading.dataVersion) { _, _ in
                reload()
            }
            .sheet(item: $editing) { item in
                NavigationStack {
                    Form {
                        TextField("想法…", text: $noteDraft, axis: .vertical)
                            .lineLimit(3...12)
                            .accessibilityIdentifier("notes.editor")
                        if let error = store.error {
                            Text(error).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .navigationTitle("编辑笔记")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消") { editing = nil }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("保存") {
                                if store.update(highlight: item, note: noteDraft, using: runtime) {
                                    editing = nil
                                    reading.markDirty()
                                }
                            }
                            .accessibilityIdentifier("notes.save")
                        }
                    }
                }
                .presentationDetents([.medium, .large])
            }
            .sheet(item: $share) { item in
                NavigationStack {
                    VStack(spacing: 14) {
                        Image(systemName: "doc.text").font(.largeTitle).foregroundStyle(.secondary)
                        Text(item.url.lastPathComponent).font(.footnote.weight(.semibold))
                        ShareLink(item: item.url) {
                            Label("分享 / 存到「文件」", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        Text("在分享面板里选「存储到文件」就能存进 iCloud 或本机文件。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Spacer(minLength: 0)
                    }
                    .padding(20)
                    .navigationTitle("导出")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { share = nil }
                        }
                    }
                }
                .presentationDetents([.height(320)])
            }
            .alert("导出失败", isPresented: Binding(
                get: { exportError != nil },
                set: { if !$0 { exportError = nil } }
            )) {
                Button("知道了", role: .cancel) { exportError = nil }
            } message: {
                Text(exportError ?? "")
            }
        }
    }

    private var visibleItems: [HighlightItem] {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matches: (HighlightItem) -> Bool = { item in
            guard !keyword.isEmpty else { return true }
            return item.text.lowercased().contains(keyword)
                || (item.note ?? "").lowercased().contains(keyword)
                || (item.bookTitle ?? "").lowercased().contains(keyword)
                || (item.chapterTitle ?? "").lowercased().contains(keyword)
        }
        switch mode {
        case .highlights: return store.highlights.filter(matches)
        case .notes: return store.highlights.filter { !($0.note ?? "").isEmpty }.filter(matches)
        case .bookmarks: return []
        }
    }

    private func reload() {
        store.refresh(using: runtime)
        library.refresh(using: runtime)
        store.refreshBookmarks(using: runtime)
    }

    private var bookmarkList: some View {
        List {
            ForEach(visibleBookmarks) { item in
                Button {
                    open(bookId: item.bookId, cfi: item.cfi)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(library.books.first { $0.id == item.bookId }?.title ?? "未知书籍")
                            .font(.footnote.weight(.semibold))
                        HStack(spacing: 6) {
                            Image(systemName: "bookmark.fill").font(.caption2)
                            Text(item.chapterTitle?.isEmpty == false ? item.chapterTitle! : "位置 \(item.label ?? "")")
                                .font(.caption)
                            Spacer(minLength: 0)
                            Text(dateText(item.createdAt)).font(.caption2)
                        }
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing) {
                    Button("删除", role: .destructive) {
                        store.delete(bookmark: item, using: runtime)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var list: some View {
        List {
            ForEach(groupedKeys, id: \.self) { key in
                Section {
                    ForEach(grouped[key] ?? []) { item in
                        row(item)
                    }
                } header: {
                    Text(grouped[key]?.first?.bookTitle ?? "未知书籍")
                        .font(.footnote.weight(.semibold))
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var grouped: [String: [HighlightItem]] {
        Dictionary(grouping: visibleItems, by: { $0.bookId })
    }

    private var groupedKeys: [String] {
        grouped.keys.sorted { left, right in
            (grouped[left]?.first?.createdAt ?? 0) > (grouped[right]?.first?.createdAt ?? 0)
        }
    }

    private var visibleBookmarks: [BookmarkItem] {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !keyword.isEmpty else { return store.bookmarks }
        return store.bookmarks.filter { item in
            item.chapterTitle?.lowercased().contains(keyword) == true
                || item.label?.lowercased().contains(keyword) == true
                || (library.books.first { $0.id == item.bookId }?.title.lowercased().contains(keyword) == true)
        }
    }

    private func row(_ item: HighlightItem) -> some View {
        Button {
            open(item)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle().fill(item.colorValue).frame(width: 8, height: 8)
                    if let chapter = item.chapterTitle, !chapter.isEmpty {
                        Text(chapter).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Text(dateText(item.createdAt)).font(.caption2).foregroundStyle(.secondary)
                }
                Text(item.text)
                    .font(.subheadline)
                    .foregroundStyle(Color(.label))
                    .lineLimit(4)
                if let note = item.note, !note.isEmpty {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 8)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(Theme.hairline).frame(width: 2)
                        }
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button("删除", role: .destructive) {
                store.delete(highlight: item, using: runtime)
            }
        }
        .swipeActions(edge: .leading) {
            Button("编辑") {
                noteDraft = item.note ?? ""
                editing = item
            }
        }
    }

    private func open(_ item: HighlightItem) {
        open(bookId: item.bookId, cfi: item.cfi)
    }

    private func open(bookId: String, cfi: String) {
        guard let book = library.books.first(where: { $0.id == bookId }) else { return }
        reading.pendingLocation = cfi
        reading.book = book
        reading.isReaderPresented = true
    }

    private func dateText(_ millis: Double) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd"
        return formatter.string(from: Date(timeIntervalSince1970: millis / 1000))
    }

    // MARK: - 导出（Markdown / HTML）

    private enum ExportFormat {
        case markdown
        case html

        var label: String {
            switch self {
            case .markdown: "Markdown"
            case .html: "HTML"
            }
        }

        var fileExtension: String {
            switch self {
            case .markdown: "md"
            case .html: "html"
            }
        }
    }

    private struct ExportEntry {
        let text: String
        let note: String?
        let meta: String
    }

    private func export(_ format: ExportFormat) {
        let stamp = Self.stamp()
        let content = format == .markdown ? markdownExport(stamp) : htmlExport(stamp)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("shudeng-export", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("书灯笔记-\(stamp).\(format.fileExtension)")
            try content.write(to: url, atomically: true, encoding: .utf8)
            share = NotesExport(url: url, label: "导出 \(format.label)")
        } catch {
            exportError = String(describing: error)
        }
    }

    /// 按书分组的导出条目：高亮 / 笔记一份，书签一份。
    private var exportSections: [(title: String, entries: [ExportEntry])] {
        var sections: [(title: String, entries: [ExportEntry])] = []
        let grouped = Dictionary(grouping: store.highlights, by: { $0.bookId })
        let orderedKeys = grouped.keys.sorted { left, right in
            (grouped[left]?.map(\.createdAt).max() ?? 0) > (grouped[right]?.map(\.createdAt).max() ?? 0)
        }
        for key in orderedKeys {
            guard let items = grouped[key] else { continue }
            let title = items.first?.bookTitle ?? bookTitle(for: key)
            let entries = items
                .sorted { $0.createdAt < $1.createdAt }
                .map { item in
                    let chapter = item.chapterTitle?.isEmpty == false ? " · \(item.chapterTitle!)" : ""
                    return ExportEntry(
                        text: item.text,
                        note: item.note?.isEmpty == false ? item.note : nil,
                        meta: "\(Self.stamp(item.createdAt))\(chapter)"
                    )
                }
            sections.append((title, entries))
        }
        if !store.bookmarks.isEmpty {
            let entries = store.bookmarks.map { item in
                let chapter = item.chapterTitle?.isEmpty == false ? item.chapterTitle! : "位置 \(item.label ?? "")"
                return ExportEntry(
                    text: chapter,
                    note: nil,
                    meta: "\(Self.stamp(item.createdAt)) · \(bookTitle(for: item.bookId))"
                )
            }
            sections.append(("书签", entries))
        }
        return sections
    }

    private func markdownExport(_ stamp: String) -> String {
        var lines = ["# 书灯 · 笔记导出", "", "导出时间：\(stamp)", ""]
        for section in exportSections {
            lines.append("## 《\(section.title)》")
            lines.append("")
            for entry in section.entries {
                lines.append("> \(entry.text.replacingOccurrences(of: "\n", with: " "))")
                if let note = entry.note {
                    lines.append("")
                    lines.append("笔记：\(note)")
                }
                lines.append("")
                lines.append("- \(entry.meta)")
                lines.append("")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func htmlExport(_ stamp: String) -> String {
        var body = ""
        for section in exportSections {
            body += "<h2>《\(Self.escape(section.title))》</h2>\n"
            for entry in section.entries {
                body += "<blockquote>\(Self.escape(entry.text))</blockquote>\n"
                if let note = entry.note {
                    body += "<p class=\"note\">笔记：\(Self.escape(note))</p>\n"
                }
                body += "<p class=\"meta\">\(Self.escape(entry.meta))</p>\n"
            }
        }
        return """
        <!doctype html>
        <html lang="zh-CN">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>书灯 · 笔记导出</title>
        <style>
        body { font: 16px/1.75 -apple-system, "PingFang SC", system-ui, sans-serif; max-width: 720px; margin: 40px auto; padding: 0 20px; color: #111; }
        h1 { font-size: 22px; }
        h2 { font-size: 17px; margin-top: 30px; padding-bottom: 6px; border-bottom: 1px solid #e2e2e2; }
        blockquote { margin: 10px 0 4px; padding-left: 12px; border-left: 3px solid #d4d4d4; color: #222; }
        .note { margin: 4px 0 4px 12px; color: #555; }
        .meta { margin: 0 0 14px; color: #999; font-size: 13px; }
        </style>
        </head>
        <body>
        <h1>书灯 · 笔记导出</h1>
        <p class="meta">导出时间：\(stamp)</p>
        \(body)</body>
        </html>
        """
    }

    private func bookTitle(for bookId: String) -> String {
        library.books.first { $0.id == bookId }?.title ?? "未知书籍"
    }

    private static func stamp(_ millis: Double? = nil) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let date = millis.map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
        return formatter.string(from: date)
    }

    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
