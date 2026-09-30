// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var runtime: RuntimeHost
    @EnvironmentObject private var reading: ReadingSession
    @StateObject private var store = LibraryStore()
    @State private var showImporter = false

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 20)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    searchField
                        .padding(.horizontal, 20)
                    if !store.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        semanticSection
                            .padding(.top, 18)
                    }
                    filterRow
                        .padding(.horizontal, 20)
                        .padding(.top, 14)
                    notices
                    if store.books.isEmpty {
                        EmptyHint(
                            title: "书架还是空的",
                            message: "从「文件」里挑一本 EPUB 或 PDF，或者用 AirDrop 发过来。",
                            action: ("导入第一本书", { showImporter = true })
                        )
                        .padding(.top, 120)
                    } else if store.visibleBooks.isEmpty {
                        EmptyLine(text: "没有匹配的书，换个关键词或筛选条件试试")
                            .padding(.top, 120)
                    } else {
                        LazyVGrid(columns: columns, spacing: 26) {
                            ForEach(store.visibleBooks) { book in
                                bookCell(book)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 22)
                    }
                }
                .padding(.top, 2)
                .padding(.bottom, 28)
            }
            .scrollDismissesKeyboard(.immediately)
            .background(Color(.systemBackground))
            .toolbar {
                Button {
                    showImporter = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityIdentifier("library.import")
                .disabled(runtime.state != .ready)
                Button {
                    store.refresh(using: runtime)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityIdentifier("library.refresh")
                .disabled(runtime.state != .ready)
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.epub, .pdf],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    store.importBook(from: url, using: runtime)
                case .failure(let error):
                    store.report(error)
                }
            }
            .task { store.refresh(using: runtime) }
            .task(id: store.query) {
                // 边打字边在已建索引的书里搜段落，350ms 防抖，别每个字符都算一次向量。
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled else { return }
                await store.searchSemantics(query: store.query, using: runtime)
            }
            // 索引建完（已建索引的书变多）时把当前搜索重跑一次，不然结果要等下次打字才出来。
            .task(id: store.indexedBooks.count) {
                await store.searchSemantics(query: store.query, using: runtime)
            }
            .onChange(of: runtime.state) { _, _ in store.refresh(using: runtime) }
            .onChange(of: reading.dataVersion) { _, _ in store.refresh(using: runtime) }
        }
    }

    private func open(_ book: LibraryStore.Book) {
        reading.pendingLocation = nil
        reading.pendingSnippet = nil
        reading.book = book
        reading.isReaderPresented = true
    }

    /// 语义检索命中：开书并让阅读器按原文片段定位（索引里没有 cfi）。
    private func open(_ hit: LibraryStore.SemanticHit) {
        guard let book = store.books.first(where: { $0.id == hit.bookId }) else { return }
        reading.pendingLocation = nil
        reading.pendingSnippet = hit.jumpText
        reading.book = book
        reading.isReaderPresented = true
    }

    @ViewBuilder
    private var semanticSection: some View {
        if !store.indexedBooks.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text(store.isSearchingSemantics ? "在书里找…" : "书里的段落")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 6)
                .accessibilityIdentifier("library.semanticHeader")

                ForEach(store.semanticHits) { hit in
                    Button {
                        open(hit)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(hit.chapterTitle.isEmpty ? hit.bookTitle : hit.chapterTitle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Text(hit.bookTitle)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                            Text(hit.content.replacingOccurrences(of: "\n", with: " "))
                                .font(.callout)
                                .foregroundStyle(Color.primary)
                                .lineLimit(3)
                                .multilineTextAlignment(.leading)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("library.semanticHit")
                    Divider().padding(.leading, 20)
                }

                ForEach(store.semanticFailures, id: \.bookId) { failure in
                    Text("这本书的索引要重建：\(failure.message)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                }
            }
        } else if !store.books.isEmpty {
            Text("长按书封可以建立语义索引，之后就能在这里按意思找段落")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField("搜索书名 / 作者", text: $store.query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.subheadline)
            if !store.query.isEmpty {
                Button {
                    store.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
                .accessibilityIdentifier("library.searchClear")
                .accessibilityLabel("清空搜索")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).fill(Color(.secondarySystemFill)))
    }

    private var filterRow: some View {
        HStack(spacing: 12) {
            Picker("筛选", selection: $store.filter) {
                ForEach(LibraryStore.ReadingFilter.allCases) { item in
                    Text(item.label).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("library.filter")

            Menu {
                ForEach(LibraryStore.SortField.allCases) { field in
                    Button {
                        store.sort = field
                    } label: {
                        Text(store.sort == field ? "✓ \(field.label)" : field.label)
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.subheadline.weight(.medium))
                    .frame(width: 30, height: 30)
            }
            .accessibilityLabel(store.sort.label)
            .accessibilityIdentifier("library.sort")
        }
    }

    @ViewBuilder
    private var notices: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = store.error {
                Text(error)
            }
            if let indexError = store.indexError {
                Text(indexError)
            }
            if let notice = store.notice {
                Text(notice)
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bookCell(_ book: LibraryStore.Book) -> some View {
        Button {
            open(book)
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                cover(book, width: nil)
                if book.progressValue > 0 {
                    ThinProgressBar(value: book.progressValue, height: 2)
                }
                Text(book.title)
                    .font(.footnote.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if store.indexingBookId == book.id {
                    Text("建索引 \(Int(store.indexingProgress * 100))%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("library.book")
        .accessibilityLabel(bookLabel(book))
        .contextMenu {
            Button("开始阅读", systemImage: "book") { open(book) }
            if book.isEpub {
                if store.indexingBookId == book.id {
                    Button("正在建索引 \(Int(store.indexingProgress * 100))%…", systemImage: "hourglass") {}
                        .disabled(true)
                } else if store.isIndexed(book) {
                    Button("重建语义索引", systemImage: "arrow.clockwise") {
                        store.buildIndex(for: book, using: runtime)
                    }
                    Button("删除语义索引", systemImage: "trash") {
                        store.deleteIndex(for: book, using: runtime)
                    }
                } else {
                    Button("建立语义索引", systemImage: "magnifyingglass") {
                        store.buildIndex(for: book, using: runtime)
                    }
                }
            }
            Button("从书库删除", systemImage: "trash", role: .destructive) {
                store.delete(book, using: runtime)
            }
        }
    }

    /// 屏幕上看不到的信息（作者、进度、索引状态）留给读屏和自动化断言。
    private func bookLabel(_ book: LibraryStore.Book) -> String {
        var parts = [book.title]
        if !book.author.isEmpty { parts.append(book.author) }
        parts.append(book.progressValue > 0 ? "已读 \(Int((book.progressValue * 100).rounded()))%" : "未读")
        if store.isIndexed(book) { parts.append("已建语义索引") }
        return parts.joined(separator: "，")
    }

    @ViewBuilder
    private func cover(_ book: LibraryStore.Book, width: CGFloat?) -> some View {
        Color.clear
            .aspectRatio(2 / 3, contentMode: .fit)
            .frame(width: width)
            .overlay {
                if let image = store.coverImage(for: book, root: runtime.rootDirectory) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    CoverPlaceholder(title: book.title, author: book.author)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.coverRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.coverRadius, style: .continuous)
                    .strokeBorder(Theme.coverBorder, lineWidth: 0.5)
            )
            .shadow(color: Theme.coverShadow, radius: 5, x: 0, y: 2)
    }
}
