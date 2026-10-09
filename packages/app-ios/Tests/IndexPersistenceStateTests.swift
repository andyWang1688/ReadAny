// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

final class RuntimeHost {
    enum State { case ready }
    var state = State.ready
    var deleteFails = true, readFails = false
    var receipt = #"{"ok":true}"#
    var indexState = "running"
    var rows = #"[{"bookId":"b","title":"Book","modelId":"m","dimensions":2,"isVectorized":true}]"#
    func appJSON(_ expression: String, timeout: TimeInterval = 30) throws -> String? {
        if expression.contains("deleteVectors") {
            if deleteFails { throw NSError(domain: "SQLITE_BUSY", code: 5) }
            return receipt
        }
        if expression.contains("vectorizeStatus") {
            return "{\"status\":\"\(indexState)\",\"bookId\":\"b\",\"progress\":0.5,\"chunks\":1}"
        }
        if readFails { throw NSError(domain: "SQLITE_BUSY", code: 5) }
        return rows
    }
    func appJSONOr(_ expression: String, fallback: String = "{}", timeout: TimeInterval = 30) -> String {
        (try? appJSON(expression, timeout: timeout)) ?? fallback
    }
}

@main struct Tests {
    static func main() throws {
        var failures = 0, checks = 0
        func expect(_ value: Bool, _ message: String) {
            checks += 1
            if !value { failures += 1; print("FAIL: " + message) }
        }
        let host = RuntimeHost(), library = LibraryStore()
        let book = try JSONDecoder().decode(LibraryStore.Book.self, from: Data(#"{"id":"b","filePath":"book.epub","meta":{"title":"Book"}}"#.utf8))
        library.refreshIndex(using: host)
        library.deleteIndex(for: book, using: host)
        expect(library.semanticHits.map(\.content) == ["hit"] && library.indexedBooks.count == 1 && library.indexError != nil, "failed deletion preserves results and surfaces error")
        expect(library.indexingBookId == "b" && library.stopped == 0, "failed deletion must not stop an active backend task")
        host.indexState = "idle"
        library.deleteIndex(for: book, using: host)
        expect(library.indexingBookId == nil && library.stopped > 0 && library.indexError != nil, "cancelled backend task stops polling even when deletion fails")
        host.readFails = true
        library.refreshIndex(using: host)
        expect(library.indexedBooks.count == 1, "failed refresh preserves indexed books")
        host.readFails = false; host.deleteFails = false
        for receipt in ["{}", #"{"error":"busy"}"#, #"{"ok":false}"#, #"{"ok":1}"#] {
            host.receipt = receipt
            library.deleteIndex(for: book, using: host)
            expect(library.semanticHits.map(\.content) == ["hit"] && library.indexError != nil, "invalid receipt must preserve library state: " + receipt)
        }
        host.receipt = #"{"ok":true}"#; host.rows = "[]"
        library.deleteIndex(for: book, using: host)
        expect(library.semanticHits.isEmpty && library.indexedBooks.isEmpty && library.indexError == nil, "successful retry clears deleted index and error")

        let vector = VectorProbe()
        vector.load()
        let indexed = vector.books[0]
        vector.remove(indexed)
        expect(vector.books.count == 1 && vector.error != nil, "settings failed deletion retains row with visible error")
        vector.runtime.readFails = true
        vector.load()
        expect(vector.books.count == 1 && vector.error != nil, "settings failed read retains rows")
        vector.runtime.readFails = false; vector.runtime.deleteFails = false
        for receipt in ["{}", #"{"error":"busy"}"#, #"{"ok":false}"#, #"{"ok":1}"#] {
            vector.runtime.receipt = receipt
            vector.remove(indexed)
            expect(vector.books.count == 1 && vector.error != nil, "settings invalid receipt retains row: " + receipt)
        }
        vector.runtime.receipt = #"{"ok":true}"#; vector.runtime.rows = "[]"
        vector.remove(indexed)
        expect(vector.books.isEmpty && vector.error == nil, "settings deletion retry succeeds")

        let partialHost = RuntimeHost(), partial = LibraryStore()
        partial.refreshIndex(using: partialHost)
        partialHost.rows = "[]"
        partialHost.readFails = true
        partial.deleteIndex(for: book, using: partialHost)
        expect(partial.indexedBooks.count == 1 && partial.semanticHits.count == 1 && partial.indexError != nil, "partial deletion plus failed refresh preserves last known rows and hits")
        partialHost.readFails = false
        partial.deleteIndex(for: book, using: partialHost)
        expect(partial.indexedBooks.isEmpty && partial.semanticHits.isEmpty && partial.indexError != nil, "partial deletion refresh removes ghost index and stale hits while retaining deletion error")
        partialHost.readFails = true
        partial.refreshIndex(using: partialHost)
        partialHost.readFails = false
        partial.refreshIndex(using: partialHost)
        expect(partial.indexError == nil, "successful read retry clears only read error")
        partial.indexError = "deletion failed"
        partial.refreshIndex(using: partialHost)
        expect(partial.indexError == "deletion failed", "successful refresh preserves unrelated deletion error")
        let inactiveHost = RuntimeHost(), inactive = LibraryStore()
        inactiveHost.rows = inactiveHost.rows.replacingOccurrences(of: "true", with: "false")
        inactive.refreshIndex(using: inactiveHost)
        expect(inactive.indexedBooks.count == 1 && inactive.semanticHits.isEmpty, "inactive manageable index cannot retain semantic hits")

        let partialVector = VectorProbe()
        partialVector.load()
        partialVector.runtime.rows = "[]"; partialVector.runtime.readFails = true
        partialVector.remove(indexed)
        expect(partialVector.books.count == 1 && partialVector.error != nil, "settings failed refresh after partial deletion preserves rows")
        partialVector.runtime.readFails = false
        partialVector.remove(indexed)
        expect(partialVector.books.isEmpty && partialVector.error != nil, "settings partial deletion reflects actual empty index while retaining error")
        expect(partialVector.pendingRemoval?.bookId == indexed.bookId, "partially removed row keeps deletion retry target")
        partialVector.runtime.deleteFails = false
        if let retry = partialVector.pendingRemoval { partialVector.remove(retry) }
        expect(partialVector.pendingRemoval == nil && partialVector.error == nil, "explicit deletion retry completes cleanup after row disappears")
        let retryHost = RuntimeHost(), retryLibrary = LibraryStore()
        retryHost.rows = "[]"
        retryLibrary.deleteIndex(for: book, using: retryHost)
        expect(retryLibrary.pendingIndexDeletion?.id == book.id, "library partial deletion keeps a retry target after index row disappears")
        retryHost.deleteFails = false
        if let target = retryLibrary.pendingIndexDeletion { retryLibrary.deleteIndex(for: target, using: retryHost) }
        expect(retryLibrary.pendingIndexDeletion == nil && retryLibrary.indexError == nil, "library retry completes deletion and clears its target")
        guard failures == 0 else { print("\(failures)/\(checks) failed"); exit(1) }
        print("Index persistence regression passed (\(checks) checks)")
    }
}
