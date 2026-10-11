// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit

/// 未提交的笔记单独落盘；正式笔记仍只由用户点击保存后写入数据库。
enum NoteDrafts {
    private struct Draft: Codable {
        let bookId: String
        let cfi: String
        let original: String
        let text: String
    }

    private static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("unsaved-notes", isDirectory: true)
    }

    private static func name(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func bookDirectory(_ bookId: String) -> URL {
        directory.appendingPathComponent(name(bookId), isDirectory: true)
    }

    private static func file(bookId: String, cfi: String) -> URL {
        bookDirectory(bookId).appendingPathComponent(name(cfi)).appendingPathExtension("json")
    }

    static func restore(bookId: String, cfi: String, original: String) throws -> String? {
        let url = file(bookId: bookId, cfi: cfi)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let draft = try JSONDecoder().decode(Draft.self, from: Data(contentsOf: url))
        // 正式内容已变更时，不用旧草稿覆盖新笔记。
        guard draft.bookId == bookId, draft.cfi == cfi, draft.original == original else { return nil }
        return draft.text
    }

    static func preserve(bookId: String, cfi: String, original: String, text: String) throws {
        guard text != original else {
            try discard(bookId: bookId, cfi: cfi)
            return
        }
        let url = file(bookId: bookId, cfi: cfi)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let draft = Draft(bookId: bookId, cfi: cfi, original: original, text: text)
        try JSONEncoder().encode(draft).write(to: url, options: .atomic)
    }

    static func discard(bookId: String, cfi: String) throws {
        let url = file(bookId: bookId, cfi: cfi)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    static func discard(bookId: String) throws {
        let url = bookDirectory(bookId)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
