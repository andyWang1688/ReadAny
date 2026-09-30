// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// AI 栏首屏＝对话历史。
/// 读书时问 AI 的入口是「选中一句话 → ✨」，很少有人先点开 AI 栏再想问题，
/// 所以这一屏的正事是翻旧账：我问过什么、结论是什么、这段对话是哪本书里的。
struct ChatListView: View {
    @EnvironmentObject private var runtime: RuntimeHost
    @EnvironmentObject private var reading: ReadingSession
    @EnvironmentObject private var chat: ChatService
    @StateObject private var library = LibraryStore()

    @State private var openThread: ChatThread?
    @State private var startNewConversation = false
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            Group {
                if chat.threads.isEmpty {
                    empty
                } else {
                    list
                }
            }
            .background(Color(.systemBackground))
            .searchable(text: $searchText, prompt: "搜索书名或对话")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        chat.startNewThread()
                        startNewConversation = true
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityIdentifier("chat.newThread")
                    .accessibilityLabel("新对话")
                }
            }
            .navigationDestination(item: $openThread) { thread in
                ChatView()
                    .onAppear { chat.open(thread, using: runtime) }
            }
            .navigationDestination(isPresented: $startNewConversation) {
                ChatView()
            }
            .task {
                chat.refreshThreads(using: runtime)
                library.refresh(using: runtime)
            }
            .onAppear {
                // 从对话退回来时把新会话刷进列表。
                chat.refreshThreads(using: runtime)
                library.refresh(using: runtime)
            }
            .onChange(of: runtime.state) { _, _ in
                chat.refreshThreads(using: runtime)
                library.refresh(using: runtime)
            }
        }
    }

    private var list: some View {
        List {
            ForEach(bookGroups, id: \.id) { group in
                Section {
                    ForEach(group.threads) { thread in
                        Button {
                            chat.open(thread, using: runtime)
                            openThread = thread
                        } label: {
                            row(thread)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("chat.threadRow")
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            chat.delete(group.threads[index], using: runtime)
                        }
                    }
                } header: {
                    HStack(spacing: 8) {
                        Image(systemName: group.bookId == nil ? "bubble.left.and.bubble.right" : "book.closed")
                            .font(.caption.weight(.semibold))
                        Text("\(group.title) · \(group.threads.count) 段对话")
                    }
                    .foregroundStyle(.secondary)
                }
            }
            if bookGroups.isEmpty {
                Text("没有找到匹配的对话")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { chat.refreshThreads(using: runtime) }
    }

    private var bookGroups: [(id: String, title: String, bookId: String?, threads: [ChatThread])] {
        let booksByID = Dictionary(uniqueKeysWithValues: library.books.map { ($0.id, $0.title) })
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let source = chat.threads.filter { thread in
            guard !keyword.isEmpty else { return true }
            let bookTitle = thread.bookId.flatMap { booksByID[$0] } ?? ""
            return thread.title.lowercased().contains(keyword)
                || (thread.lastMessage ?? "").lowercased().contains(keyword)
                || bookTitle.lowercased().contains(keyword)
        }
        let grouped = Dictionary(grouping: source) { $0.bookId ?? "__general__" }
        return grouped.map { key, threads in
            let sorted = threads.sorted { $0.updatedAt > $1.updatedAt }
            let title: String
            let bookId: String?
            if key == "__general__" {
                title = "未归类对话"
                bookId = nil
            } else {
                title = booksByID[key] ?? "已删除的书"
                bookId = key
            }
            return (id: key, title: title, bookId: bookId, threads: sorted)
        }
        .sorted { left, right in
            (left.threads.first?.updatedAt ?? 0) > (right.threads.first?.updatedAt ?? 0)
        }
    }

    private func row(_ thread: ChatThread) -> some View {
        HStack(spacing: 12) {
            thumb(for: thread)
            VStack(alignment: .leading, spacing: 2) {
                Text(thread.title)
                    .font(.subheadline)
                    .foregroundStyle(Color(.label))
                    .lineLimit(1)
                if let last = thread.lastMessage, !last.isEmpty {
                    Text(last)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(meta(thread))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(stamp(thread))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    /// 左图：认得出是哪本书就写书名头两个字，认不出就放一个对话图标。
    @ViewBuilder
    private func thumb(for thread: ChatThread) -> some View {
        let title = library.books.first { $0.id == thread.bookId }?.title
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(Color(.secondarySystemBackground))
            .frame(width: 34, height: 46)
            .overlay {
                if let title {
                    Text(String(title.prefix(2)))
                        .font(.system(size: 11, weight: .medium, design: .serif))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                } else {
                    Image(systemName: "text.bubble")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Theme.coverBorder, lineWidth: 0.5)
            )
    }

    private func meta(_ thread: ChatThread) -> String {
        var parts: [String] = []
        if let bookId = thread.bookId, let book = library.books.first(where: { $0.id == bookId }) {
            parts.append(book.title)
        }
        if let count = thread.messageCount, count > 0 {
            parts.append("\(Int(count)) 条")
        }
        return parts.joined(separator: " · ")
    }

    private func stamp(_ thread: ChatThread) -> String {
        let date = Date(timeIntervalSince1970: thread.updatedAt / 1000)
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            return formatter.string(from: date)
        }
        if calendar.isDateInYesterday(date) { return "昨天" }
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        return formatter.string(from: date)
    }

    private var empty: some View {
        VStack {
            Spacer(minLength: 0)
            VStack(spacing: 8) {
                Text("还没有对话")
                    .font(.headline)
                Text("读书时选中一句话，点 ✨ 直接问；也可以点右上角，带着正在读的书开一段新的。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if let book = reading.book {
                    Button("带着《\(book.title)》开一段") {
                        chat.startNewThread()
                        startNewConversation = true
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .padding(.top, 10)
                    .accessibilityIdentifier("chat.emptyStart")
                } else if !library.books.isEmpty {
                    Button("开一段新对话") {
                        chat.startNewThread()
                        startNewConversation = true
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .padding(.top, 10)
                    .accessibilityIdentifier("chat.emptyStart")
                }
            }
            .padding(.horizontal, 44)
            Spacer(minLength: 0)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
