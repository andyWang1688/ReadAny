// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Host boundary: keep JS state separate from its next-main-queue Swift delivery.
@MainActor final class RuntimeHost {
    enum State { case ready }
    var state = State.ready
    var status = "idle"
    var bookId: String?
    var progress = 0.0
    var error: String?
    private(set) var callbacks: [((String) -> Void)?] = []

    func appJSON(_ expression: String, timeout: TimeInterval = 30) throws -> String? {
        if expression.contains("deleteVectors") {
            status = "idle"
            return #"{"ok":true}"#
        }
        if expression.contains("vectorizeStatus") {
            let body: [String: Any] = ["status": status, "bookId": bookId ?? NSNull(),
                                      "title": "A", "progress": progress, "chunks": 1,
                                      "error": error ?? NSNull()]
            return String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
        }
        return "[]"
    }

    func appJSONOr(_ expression: String, fallback: String = "{}", timeout: TimeInterval = 30) -> String {
        (try? appJSON(expression, timeout: timeout)) ?? fallback
    }

    func callAsync(_ expression: String, timeout: TimeInterval, onResult: @escaping (String) -> Void) {
        let start = expression.index(after: expression.firstIndex(of: "(")!)
        let data = Data(expression[start..<expression.index(before: expression.endIndex)].utf8)
        bookId = (try! JSONSerialization.jsonObject(with: data) as! [String: String])["bookId"]
        status = "running"
        progress = 0
        error = nil
        callbacks.append(onResult)
    }

    func nativeResult(_ index: Int, status: String, json: String) {
        self.status = status
        error = status == "error" ? "A failed" : nil
        // RuntimeHost.onAsyncResult dispatches once more before removing its pending callback.
        DispatchQueue.main.async {
            let callback = self.callbacks[index]
            self.callbacks[index] = nil
            callback?(json)
        }
    }
}

@main struct IndexTaskStateTests {
    @MainActor static func main() throws {
        var checks = 0, failures = 0
        func expect(_ value: Bool, _ message: String) {
            checks += 1
            if !value { failures += 1; print("FAIL: " + message) }
        }
        func book(_ id: String) throws -> LibraryStore.Book {
            let body: [String: Any] = ["id": id, "filePath": id + ".epub", "meta": ["title": id]]
            return try JSONDecoder().decode(LibraryStore.Book.self, from: JSONSerialization.data(withJSONObject: body))
        }
        let first = try book("book-A")
        for sameBook in [false, true] {
            let next = try book(sameBook ? "book-A" : "book-B")
            for terminal in ["done", "error"] {
                for deletion in [false, true] {
                    let host = RuntimeHost(), store = LibraryStore()
                    let scenario = "\(sameBook ? "same" : "other")/\(terminal)/\(deletion ? "delete" : "poll")"
                    store.books = [first, next]
                    store.buildIndex(for: first, using: host)
                    var finished = false
                    // These already-queued poll/user events can run before the native result's extra queue hop.
                    DispatchQueue.main.async {
                        host.nativeResult(0, status: terminal,
                                          json: terminal == "done" ? #"{"ok":true}"# : #"{"error":"A failed"}"#)
                    }
                    DispatchQueue.main.async {
                        if deletion {
                            store.deleteIndex(for: first, using: host)
                        } else {
                            store.pollIndexStatus(using: host)
                            if terminal == "error" {
                                expect(store.indexError?.contains("暂时无法建立索引") == true && store.failedIndexBook?.id == first.id,
                                       scenario + " poll must keep the current failure visible")
                            }
                        }
                    }
                    DispatchQueue.main.async { store.buildIndex(for: next, using: host) }
                    DispatchQueue.main.async {
                        expect(store.indexingBookId == next.id && host.callbacks.count == 2,
                               scenario + " next user request must start")
                        DispatchQueue.main.async {
                            expect(store.indexingBookId == next.id && store.indexError == nil && store.failedIndexBook == nil,
                                   scenario + " old callback must not finish or fail the new request")
                            host.progress = 0.42
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                                expect(store.indexingBookId == next.id && store.indexingProgress == 0.42,
                                       scenario + " new request must continue reporting progress")
                                host.nativeResult(1, status: "error", json: #"{"error":"B failed"}"#)
                                DispatchQueue.main.async {
                                    expect(store.indexingBookId == nil && store.indexError?.contains("暂时无法建立索引") == true && store.failedIndexBook?.id == next.id,
                                           scenario + " current callback must still finish with its own error")
                                    finished = true
                                }
                            }
                        }
                    }
                    let deadline = Date().addingTimeInterval(3)
                    while !finished && Date() < deadline {
                        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
                    }
                    expect(finished, scenario + " main-queue replay must settle")
                }
            }
        }
        let store = LibraryStore()
        store.books = [first]
        store.recordIndexFailure("文件操作失败: 文件不存在: /private/test.epub", bookId: first.id, title: first.title)
        expect(store.indexError?.contains("无法读取书籍文件") == true && store.indexError?.contains("/private") == false,
               "missing file has readable guidance without internal path")
        expect(store.failedIndexBook?.id == first.id, "retry retains the actual failed book")
        store.recordIndexFailure("系统语言模型不可用", bookId: first.id, title: first.title)
        expect(store.indexError?.contains("系统语言模型暂时无法处理") == true, "model failure explains the language boundary")
        guard failures == 0 else { print("\(failures)/\(checks) failed"); exit(1) }
        print("Index task state regression passed (8 scenarios, \(checks) checks)")
    }
}
