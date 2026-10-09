// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// AI 栏首屏＝全部对话历史。
/// 分组键是书（书的角色等于 Codex 里的「项目」）；不指定书的「临时对话」永远钉在最下。
/// 组按书名排，顶栏可以切正序 / 倒序，不跟着最近活动跳来跳去。
struct ChatListView: View {
    @EnvironmentObject private var runtime: RuntimeHost
    @EnvironmentObject private var chat: ChatService
    @StateObject private var library = LibraryStore()

    @State private var openThread: ChatThread?
    @State private var startNewConversation = false
    @State private var searchText = ""
    @State private var showSearch = false
    /// 收起来的组（默认全展开）。
    @State private var collapsedGroups: Set<String> = []
    @State private var renaming: ChatThread?
    @State private var renameText = ""
    @State private var moving: ChatThread?
    @AppStorage("shudeng.chat.groupSortDescending") private var sortDescending = false

    private struct ThreadGroup: Identifiable {
        let id: String
        let title: String
        let bookId: String?
        let threads: [ChatThread]

        var isGeneral: Bool { bookId == nil }
    }

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
            .safeAreaInset(edge: .top) {
                if let error = chat.error {
                    HStack {
                        Text(error).font(.footnote)
                            .accessibilityIdentifier("chat.listError")
                        Spacer()
                        if chat.hasUnsavedReply {
                            Button("重试保存") { chat.retryPendingReply() }
                                .accessibilityIdentifier("chat.retrySave")
                        } else {
                            Button("知道了") { chat.error = nil }
                        }
                    }
                    .padding(10)
                    .background(Color.orange.opacity(0.15))
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $searchText,
                isPresented: $showSearch,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "搜索对话"
            )
            .toolbar {
                if !chat.threads.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            showSearch.toggle()
                        } label: {
                            Image(systemName: "magnifyingglass")
                        }
                        .accessibilityIdentifier("chat.search")
                        .accessibilityLabel("搜索对话")
                    }
                    ToolbarItem(placement: .topBarTrailing) { sortMenu }
                }
                ToolbarItem(placement: .topBarTrailing) { newThreadButton }
            }
            .navigationDestination(item: $openThread) { _ in
                ChatView()
            }
            .navigationDestination(isPresented: $startNewConversation) {
                ChatView()
            }
            .sheet(item: $renaming) { _ in
                NavigationStack {
                    Form {
                        TextField("对话名称", text: $renameText)
                            .accessibilityIdentifier("chat.renameEditor")
                        if let error = chat.error {
                            Text(error).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .navigationTitle("重命名对话")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消") { renaming = nil }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("保存") { saveRename() }
                                .accessibilityIdentifier("chat.renameSave")
                        }
                    }
                }
                .presentationDetents([.medium])
                .interactiveDismissDisabled()
            }
            .sheet(item: $moving) { thread in
                BookPickerSheet(
                    books: library.books,
                    selectedBookId: thread.bookId
                ) { bookId in
                    chat.move(thread, to: bookId, using: runtime)
                }
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

    private var newThreadButton: some View {
        Button {
            if chat.startNewThread() { startNewConversation = true }
        } label: {
            Image(systemName: "plus")
        }
        .accessibilityIdentifier("chat.newThread")
        .accessibilityLabel("新对话")
    }

    private var sortMenu: some View {
        Menu {
            Picker("排序", selection: $sortDescending) {
                Text("名称 A → Z").tag(false)
                Text("名称 Z → A").tag(true)
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .accessibilityIdentifier("chat.sort")
        .accessibilityLabel("分组排序")
    }

    private func saveRename() {
        guard let thread = renaming else { return }
        if chat.rename(thread, to: renameText, using: runtime) {
            renaming = nil
        }
    }

    private var list: some View {
        List {
            ForEach(groups) { group in
                Section(isExpanded: expandedBinding(group.id)) {
                    ForEach(group.threads) { thread in
                        Button {
                            if chat.open(thread, using: runtime) { openThread = thread }
                        } label: {
                            row(thread)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("chat.threadRow")
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                chat.delete(thread, using: runtime)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                            Button {
                                renameText = thread.title
                                renaming = thread
                            } label: {
                                Label("重命名", systemImage: "pencil")
                            }
                            .tint(.gray)
                        }
                        .contextMenu {
                            Button {
                                moving = thread
                            } label: {
                                Label("移到某本书", systemImage: "book")
                            }
                            Button {
                                renameText = thread.title
                                renaming = thread
                            } label: {
                                Label("重命名", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                chat.delete(thread, using: runtime)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    HStack(spacing: 8) {
                        Image(systemName: group.isGeneral ? "bubble.left" : "book")
                            .font(.caption.weight(.semibold))
                        Text(group.title)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            if groups.isEmpty {
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

    private func expandedBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { !collapsedGroups.contains(id) },
            set: { isOpen in
                if isOpen { collapsedGroups.remove(id) } else { collapsedGroups.insert(id) }
            }
        )
    }

    /// 先生成组，再排序：书按书名（可正可倒），「临时对话」永远排最后。
    private var groups: [ThreadGroup] {
        let booksByID = Dictionary(uniqueKeysWithValues: library.books.map { ($0.id, $0.title) })
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let source = chat.threads.filter { thread in
            guard !keyword.isEmpty else { return true }
            let bookTitle = thread.bookId.flatMap { booksByID[$0] } ?? ""
            return thread.title.lowercased().contains(keyword)
                || (thread.lastMessage ?? "").lowercased().contains(keyword)
                || bookTitle.lowercased().contains(keyword)
        }
        var result = Dictionary(grouping: source) { $0.bookId ?? "" }.map { key, threads -> ThreadGroup in
            let sorted = threads.sorted { $0.updatedAt > $1.updatedAt }
            guard !key.isEmpty else {
                return ThreadGroup(id: key, title: "临时对话", bookId: nil, threads: sorted)
            }
            return ThreadGroup(id: key, title: booksByID[key] ?? "已删除的书", bookId: key, threads: sorted)
        }
        result.sort { left, right in
            if left.isGeneral != right.isGeneral { return right.isGeneral }
            let order = left.title.localizedStandardCompare(right.title)
            return sortDescending ? order == .orderedDescending : order == .orderedAscending
        }
        return result
    }

    private func row(_ thread: ChatThread) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
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
            }
            Spacer(minLength: 8)
            Text(stamp(thread))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
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
        Text("点右上角 ＋ 和 AI 聊聊")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
