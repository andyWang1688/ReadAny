// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// 语义检索用哪个向量模型、哪些书建过索引。
struct VectorModelView: View {
    @EnvironmentObject private var runtime: RuntimeHost
    @State private var info: LibraryStore.EmbeddingInfo?
    @State private var books: [LibraryStore.VectorizedBook] = []
    @State private var error: String?
    @State private var pendingRemoval: LibraryStore.VectorizedBook?

    var body: some View {
        List {
            if let error {
                Section {
                    Text(error).font(.footnote).foregroundStyle(.secondary)
                    Button("重试读取") { load() }
                }
                .accessibilityIdentifier("vector.error")
            }
            if let pendingRemoval {
                Button("重试删除《\(pendingRemoval.title)》索引") { remove(pendingRemoval) }
                    .accessibilityIdentifier("vector.retryRemoval")
            }
            Section {
                if let info {
                    if info.available {
                        LabeledContent("模型", value: info.modelId ?? "设备模型")
                        LabeledContent("维度", value: "\(info.dimensions ?? 0) 维")
                    } else {
                        Text(info.error ?? "这台设备上取不到索引模型")
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
                Text("索引模型")
            } footer: {
                Text("在设备上建立索引，书籍内容不会上传。首次准备可能需要联网。")
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
        do {
            let json = try runtime.appJSON("ShudengApp.vectorizedBooks()", timeout: 60) ?? ""
            books = try JSONDecoder().decode([LibraryStore.VectorizedBook].self, from: Data(json.utf8))
            error = nil
        } catch {
            self.error = "索引读取失败，已保留上次内容，请重试。"
        }
    }

    private func statusText(_ info: LibraryStore.EmbeddingInfo) -> String {
        guard info.available else { return "索引模型不可用" }
        return info.latinOnly == true ? "索引模型可用（只支持英文内容）" : "索引模型可用"
    }

    private func remove(_ book: LibraryStore.VectorizedBook) {
        do {
            let json = try runtime.appJSON(
                "ShudengApp.deleteVectors(\(LibraryStore.payload(["bookId": book.bookId])))",
                timeout: 60
            ) ?? ""
            struct Receipt: Decodable { let ok: Bool }
            guard try JSONDecoder().decode(Receipt.self, from: Data(json.utf8)).ok else {
                throw NSError(domain: "IndexPersistence", code: 1)
            }
        } catch {
            pendingRemoval = book
            load()
            self.error = "《\(book.title)》索引删除未全部完成，请重试。"
            return
        }
        pendingRemoval = nil
        books.removeAll { $0.bookId == book.bookId }
        load()
    }
}
