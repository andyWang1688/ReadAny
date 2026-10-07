// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// 给一段对话挑书：临时对话（不指定书）+ 最近在读 + 全部书籍。
/// 新建对话和事后换书都走这一个面板。
struct BookPickerSheet: View {
    let books: [LibraryStore.Book]
    let selectedBookId: String?
    let onPick: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row(
                        title: "临时对话",
                        subtitle: "不指定书，问跟某本书无关的事",
                        icon: "bubble.left",
                        selected: selectedBookId == nil
                    ) {
                        pick(nil)
                    }
                    .accessibilityIdentifier("chat.bookPicker.general")
                }

                if !reading.isEmpty {
                    Section("正在读") {
                        ForEach(reading) { book in
                            bookRow(book)
                        }
                    }
                }

                if !others.isEmpty {
                    Section(reading.isEmpty ? "书籍" : "全部书籍") {
                        ForEach(others) { book in
                            bookRow(book)
                        }
                    }
                }

                if books.isEmpty {
                    Text("书库里还没有书")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowBackground(Color.clear)
                }
            }
            .accessibilityIdentifier("chat.bookPicker")
            .searchable(text: $query, prompt: "搜索书库")
            .navigationTitle("选择书籍")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// 最近在读：打开过、还没读完的，按最近打开排。
    private var reading: [LibraryStore.Book] {
        matched
            .filter { ($0.lastOpenedAt ?? 0) > 0 && $0.progressValue < 0.995 }
            .sorted { ($0.lastOpenedAt ?? 0) > ($1.lastOpenedAt ?? 0) }
            .prefix(3)
            .map { $0 }
    }

    private var others: [LibraryStore.Book] {
        let readingIds = Set(reading.map(\.id))
        return matched
            .filter { !readingIds.contains($0.id) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private var matched: [LibraryStore.Book] {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !keyword.isEmpty else { return books }
        return books.filter {
            $0.title.lowercased().contains(keyword) || $0.author.lowercased().contains(keyword)
        }
    }

    private func bookRow(_ book: LibraryStore.Book) -> some View {
        row(
            title: book.title,
            subtitle: subtitle(book),
            icon: "book",
            selected: book.id == selectedBookId
        ) {
            pick(book.id)
        }
        .accessibilityIdentifier("chat.bookPicker.book")
        .accessibilityLabel(book.title)
    }

    private func subtitle(_ book: LibraryStore.Book) -> String {
        guard book.progressValue > 0.001 else { return book.author }
        return "\(book.author) · 已读 \(Int((book.progressValue * 100).rounded()))%"
    }

    private func row(
        title: String,
        subtitle: String,
        icon: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline)
                        .foregroundStyle(Color(.label))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color(.label))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func pick(_ bookId: String?) {
        onPick(bookId)
        dismiss()
    }
}
