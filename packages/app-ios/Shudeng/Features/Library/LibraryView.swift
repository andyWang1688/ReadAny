// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var runtime: RuntimeHost
    @EnvironmentObject private var reading: ReadingSession
    @StateObject private var store = LibraryStore()
    @State private var showImporter = false
    @State private var bookToDelete: LibraryStore.Book?
    /// 搜索框焦点：键盘上的「收起键盘」和点空白处都要能把它放掉。
    @FocusState private var searchFocused: Bool

    private var columns: [GridItem] {
        dynamicTypeSize.isAccessibilitySize
            ? [GridItem(.flexible())]
            : [GridItem(.adaptive(minimum: 104), spacing: 20, alignment: .top)]
    }

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
            .refreshable { store.refresh(using: runtime) }
            .background(Color(.systemBackground).onTapGesture { searchFocused = false })
            .navigationTitle("书架")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button {
                    showImporter = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityIdentifier("library.import")
                .accessibilityLabel("导入书籍")
                .disabled(runtime.state != .ready)
                Button {
                    store.refresh(using: runtime)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityIdentifier("library.refresh")
                .accessibilityLabel("刷新书架")
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
            .alert("删除《\(bookToDelete?.title ?? "")》？", isPresented: Binding(
                get: { bookToDelete != nil },
                set: { if !$0 { bookToDelete = nil } }
            ), presenting: bookToDelete) { book in
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) { store.delete(book, using: runtime) }
            } message: { _ in
                Text("将同时删除这本书的高亮、笔记、书签、聊天和阅读记录，无法撤销。")
            }
            .task { store.refresh(using: runtime) }
            .task(id: store.query) {
                // 边打字边在已建索引的书里搜段落，350ms 防抖，别每个字符都算一次向量。
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled else { return }
                await store.searchSemantics(query: store.query, using: runtime)
            }
            // 索引集合变化或重建结束时，重跑当前关键词；正在建索引时不启动这次检索。
            .task(id: store.indexedBooks.map(\.bookId) + [store.indexingBookId ?? ""]) {
                guard store.indexingBookId == nil else { return }
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
        reading.pendingSnippet = hit.snippet(matching: store.query)
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

                if let error = store.semanticError {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("library.semanticError")
                        Button {
                            Task { await store.searchSemantics(query: store.query, using: runtime) }
                        } label: {
                            Text("重试").frame(minHeight: 44)
                        }
                        .font(.footnote.weight(.semibold))
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("library.semanticRetry")
                        .disabled(store.isSearchingSemantics)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                } else if !store.isSearchingSemantics && store.semanticHits.isEmpty && store.semanticFailures.isEmpty {
                    Text(store.query.trimmingCharacters(in: .whitespacesAndNewlines).count < 2
                         ? "输入至少两个字后，可以按意思找段落。"
                         : "没有找到匹配的段落，试试其他关键词。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .accessibilityIdentifier("library.semanticEmpty")
                }

                ForEach(store.semanticHits) { hit in
                    Button {
                        open(hit)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(hit.chapterTitle.isEmpty ? hit.bookTitle : hit.chapterTitle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                            Text(hit.bookTitle)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                            Text(hit.snippet(matching: store.query))
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
                    let book = store.books.first { $0.id == failure.bookId }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("《\(book?.title ?? "这本书")》的索引暂时无法使用。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("library.semanticBookError")
                        if let book {
                            Text("重建索引后再试，原书和笔记会保留。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button {
                                store.buildIndex(for: book, using: runtime)
                            } label: {
                                Text(store.indexingBookId == book.id ? "正在重建…" : "重建索引")
                                    .frame(minHeight: 44)
                            }
                            .font(.footnote.weight(.semibold))
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("library.semanticRebuild")
                            .disabled(store.indexingBookId != nil)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
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
            TextField(dynamicTypeSize.isAccessibilitySize ? "搜索书籍" : "搜索书名 / 作者", text: $store.query)
                .focused($searchFocused)
                .submitLabel(.search)
                .onSubmit { searchFocused = false }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.subheadline)
                .accessibilityIdentifier("library.searchField")
                .accessibilityLabel("搜索书名或作者")
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
        .padding(.vertical, 8)
        .frame(minHeight: 38)
        .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).fill(Color(.secondarySystemFill)))
    }

    private var filterRow: some View {
        HStack(spacing: 12) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    readingFilter.pickerStyle(.menu)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    readingFilter.pickerStyle(.segmented)
                }
            }
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
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(store.sort.label)
            .accessibilityIdentifier("library.sort")
        }
    }

    private var readingFilter: some View {
        Picker("筛选", selection: $store.filter) {
            ForEach(LibraryStore.ReadingFilter.allCases) { item in
                Text(item.label).tag(item)
            }
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
                    .accessibilityIdentifier("library.indexError")
            }
            if let book = store.failedIndexBook {
                Button { store.buildIndex(for: book, using: runtime) } label: {
                    Text("重试建立索引").frame(minHeight: 44)
                }
                .buttonStyle(.bordered)
                .disabled(store.indexingBookId != nil)
                .foregroundStyle(.primary)
                .accessibilityIdentifier("library.retryIndexBuild")
            }
            if let book = store.pendingIndexDeletion {
                Button("重试删除《\(book.title)》索引") {
                    store.deleteIndex(for: book, using: runtime)
                }
                .accessibilityIdentifier("library.retryIndexDeletion")
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
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(HStackLayout(alignment: .top, spacing: 14))
                : AnyLayout(VStackLayout(alignment: .leading, spacing: 7))
            layout {
                VStack(spacing: 7) {
                    cover(book, width: dynamicTypeSize.isAccessibilitySize ? 72 : nil)
                        .dynamicTypeSize(dynamicTypeSize.isAccessibilitySize ? .large : dynamicTypeSize)
                    if book.progressValue > 0 {
                        ThinProgressBar(value: book.progressValue, height: 2)
                    }
                }
                .frame(width: dynamicTypeSize.isAccessibilitySize ? 72 : nil)
                VStack(alignment: .leading, spacing: 7) {
                    Text(book.title)
                        .font(.footnote.weight(.medium))
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                        .multilineTextAlignment(.leading)
                    if store.indexingBookId == book.id {
                        Text("建索引 \(Int(store.indexingProgress * 100))%")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
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
                bookToDelete = book
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
