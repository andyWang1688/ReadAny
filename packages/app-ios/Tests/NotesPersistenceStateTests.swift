import Foundation
import SwiftUI
extension Color { init(hex: String) { self = .yellow } }
struct Reading {
    struct Book { let id = "b" }
    var book: Book? = Book()
    var cfi = "cfi", fraction = 0.5, chapterTitle = "chapter"
    var dirty = 0
    mutating func markDirty() { dirty += 1 }
}
@MainActor final class RuntimeHost {
    enum State { case ready }
    var state = State.ready
    var failPrefix = ""
    var invalidReceipt = false
    var highlightJSON = #"[{"id":"h","bookId":"b","cfi":"cfi","text":"original","color":"yellow","note":"old","createdAt":1}]"#
    var bookmarkJSON = #"[{"id":"bm","bookId":"b","cfi":"cfi","createdAt":1}]"#
    func appJSON(_ expression: String, timeout: TimeInterval = 30) throws -> String? {
        if !failPrefix.isEmpty && expression.hasPrefix(failPrefix) { throw NSError(domain:"fixture",code:1) }
        if expression.contains("listHighlights") { return highlightJSON }
        if expression.contains("listBookmarks") { return bookmarkJSON }
        if expression.contains("updateHighlight") { highlightJSON = highlightJSON.replacingOccurrences(of:"old",with:"new") }
        return invalidReceipt ? "{}" : "ok"
    }
    func appJSONOr(_ expression: String, fallback: String = "{}", timeout: TimeInterval = 30) -> String {
        (try? appJSON(expression,timeout:timeout)) ?? fallback
    }
}
@main struct Tests {
    @MainActor static func main() {
        var failures = 0
        func expect(_ condition: Bool, _ text: String) { if !condition { failures += 1; print("FAIL: " + text) } }
        let host = RuntimeHost(), store = NotesStore()
        store.refresh(using: host); store.refreshBookmarks(using: host)
        let highlight = store.highlights[0], bookmark = store.bookmarks[0]
        try! NoteDrafts.preserve(bookId: highlight.bookId, cfi: highlight.cfi, original: "old", text: "unsaved")
        try! NoteDrafts.preserve(bookId: "other-book", cfi: highlight.cfi, original: "", text: "keep")
        host.failPrefix = "ShudengApp.deleteHighlight"
        store.delete(highlight: highlight, using: host)
        expect(store.highlights.count == 1 && store.error != nil, "failed highlight delete must preserve row and show error")
        expect((try? NoteDrafts.restore(bookId: highlight.bookId, cfi: highlight.cfi, original: "old")) == "unsaved", "failed delete must retain draft")
        host.failPrefix = "ShudengApp.deleteBookmark"
        store.delete(bookmark: bookmark, using: host)
        expect(store.bookmarks.count == 1 && store.error != nil, "failed bookmark delete must preserve row and show error")
        host.failPrefix = "ShudengApp.updateHighlight"
        store.update(highlight: highlight, note: "new", using: host)
        expect(store.highlights.first?.note == "old" && store.error != nil, "failed update must not hide error behind successful refresh")
        host.failPrefix = "ShudengApp.listHighlights"
        store.refresh(using: host)
        expect(store.highlights.count == 1 && store.error != nil, "failed highlight load must not erase existing data")
        host.failPrefix = "ShudengApp.listBookmarks"
        store.refreshBookmarks(using: host)
        expect(store.bookmarks.count == 1 && store.error != nil, "failed bookmark load must not erase existing data")
        host.failPrefix = ""
        store.update(highlight: highlight, note: "new", using: host)
        expect(store.highlights.first?.note == "new" && store.error == nil, "retry must update note and clear error")
        store.delete(highlight: highlight, using: host)
        store.delete(bookmark: bookmark, using: host)
        expect(store.highlights.isEmpty && store.bookmarks.isEmpty, "successful delete must remove corresponding rows")
        expect((try? NoteDrafts.restore(bookId: highlight.bookId, cfi: highlight.cfi, original: "old")) == nil, "successful delete must clean its draft")
        expect((try? NoteDrafts.restore(bookId: "other-book", cfi: highlight.cfi, original: "")) == "keep", "delete must preserve other book draft")
        let reader = ReaderProbe()
        reader.bookmarks = [bookmark]
        reader.runtime.failPrefix = "ShudengApp.deleteBookmark"
        reader.toggleBookmark()
        expect(reader.bookmarks.count == 1 && reader.reading.dirty == 0 && reader.syncCalls == 0 && reader.notices.last != "已删除书签", "reader must not acknowledge a failed bookmark delete")
        reader.runtime.failPrefix = ""
        reader.runtime.invalidReceipt = true
        reader.toggleBookmark()
        expect(reader.bookmarks.count == 1, "invalid delete receipt must not remove reader bookmark")
        reader.runtime.invalidReceipt = false
        reader.toggleBookmark()
        expect(reader.bookmarks.isEmpty && reader.reading.dirty == 1 && reader.notices.last == "已删除书签", "reader delete retry must work")
        guard failures == 0 else { exit(1) }
        print("Notes and reader persistence regression passed (13 checks)")
    }
}
