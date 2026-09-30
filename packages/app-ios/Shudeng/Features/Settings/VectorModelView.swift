// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// 语义检索用哪个向量模型、哪些书建过索引。
struct VectorModelView: View {
    @EnvironmentObject private var runtime: RuntimeHost
    @State private var info: LibraryStore.EmbeddingInfo?
    @State private var books: [LibraryStore.VectorizedBook] = []

    var body: some View {
        List {
            Section {
                if let info {
                    if info.available {
                        LabeledContent("模型", value: info.modelId ?? "端侧模型")
                        LabeledContent("向量维度", value: "\(info.dimensions ?? 0) 维")
                    } else {
                        Text(info.error ?? "这台设备上取不到端侧向量模型")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("vector.diagnostics")
                    }
                    Text(statusText(info))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("vector.status")
                    if let diagnostics = info.diagnostics, !diagnostics.isEmpty {
                        Text(diagnostics)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .accessibilityIdentifier("vector.probe")
                    }
                } else {
                    Text("读取中…").foregroundStyle(.secondary).accessibilityIdentifier("vector.status")
                }
            } header: {
                Text("端侧向量模型")
            } footer: {
                Text("用系统自带的 Apple NLEmbedding：不下载模型、不出网，索引只存在这台设备上。")
            }

            Section {
                if books.isEmpty {
                    Text("还没有建立索引的书").foregroundStyle(.secondary)
                }
                ForEach(books) { book in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(book.title)
                        Text("\(book.dimensions) 维 · \(book.modelId)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .swipeActions {
                        Button("删除索引", role: .destructive) { remove(book) }
                    }
                }
            } header: {
                Text("已建索引 · \(books.count) 本")
            } footer: {
                Text("在书库长按书封可以建立或重建索引。")
            }
        }
        .navigationTitle("语义检索")
        .navigationBarTitleDisplayMode(.inline)
        .task { load() }
    }

    private func load() {
        info = LibraryStore.embeddingInfo(using: runtime)
        let json = runtime.appJSONOr("ShudengApp.vectorizedBooks()", fallback: "[]", timeout: 60)
        books = (try? JSONDecoder().decode([LibraryStore.VectorizedBook].self, from: Data(json.utf8))) ?? []
    }

    private func statusText(_ info: LibraryStore.EmbeddingInfo) -> String {
        guard info.available else { return "端侧向量模型不可用" }
        return info.latinOnly == true ? "端侧向量模型可用（只支持英文内容）" : "端侧向量模型可用"
    }

    private func remove(_ book: LibraryStore.VectorizedBook) {
        _ = runtime.appJSONOr(
            "ShudengApp.deleteVectors(\(LibraryStore.payload(["bookId": book.bookId])))",
            fallback: "{}",
            timeout: 60
        )
        load()
    }
}
