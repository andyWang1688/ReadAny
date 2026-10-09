let runtime = RuntimeHost()
var reading = Reading()
var bookmarks: [BookmarkItem] = []
var notices: [String] = []
var syncCalls = 0
func syncBookmarkPullState() { syncCalls += 1 }
func flash(_ text: String) { notices.append(text) }
func loadBookmarks(force: Bool) {}
func decodeBookmark(_ raw: String) -> BookmarkItem? { try? JSONDecoder().decode(BookmarkItem.self, from: Data(raw.utf8)) }
func json(_ payload: [String: Any]) -> String { String(decoding: try! JSONSerialization.data(withJSONObject: payload), as: UTF8.self) }
