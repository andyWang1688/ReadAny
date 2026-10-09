#!/usr/bin/env node
// SPDX-License-Identifier: GPL-3.0-or-later
// Compile the actual reader mutations and models against invalid/successful write receipts.
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const app = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const reader = readFileSync(join(app, "Shudeng/Features/Reader/ReaderScreen.swift"), "utf8");
const notes = readFileSync(join(app, "Shudeng/Features/Notes/NotesView.swift"), "utf8");
const models = notes.slice(0, notes.indexOf("@MainActor\nfinal class NotesStore"));
const method = (start, end) =>
  reader
    .slice(reader.indexOf(start), reader.indexOf(end, reader.indexOf(start)))
    .replace("private func", "func");
const highlight = method("    private func saveHighlight(", "    private func showAnnotation(");
const bookmark = method("    private func toggleBookmark()", "    /// 把「当前页是否已加书签」");
// Generate successful receipts with the backend's real methods, substituting only storage.
const bootstrap = readFileSync(
  join(app, "CoreBridge/Sources/ShudengCoreBridge/Resources/app-bootstrap.js"),
  "utf8",
);
const backendMethod = (name, next) =>
  bootstrap.slice(
    bootstrap.indexOf(`    async ${name}(input)`),
    bootstrap.indexOf(`    async ${next}(input)`),
  );
const backend = Function(
  "core",
  "bootstrap",
  "toJSON",
  `return ({${backendMethod("addHighlight", "updateHighlight")}${backendMethod("addBookmark", "deleteBookmark")}})`,
)(
  { db: { insertHighlight: async () => {}, insertBookmark: async () => {} } },
  async () => {},
  JSON.stringify,
);
const highlightReceipt = await backend.addHighlight({
  bookId: "b",
  cfi: "cfi",
  text: "original",
  color: "yellow",
});
const bookmarkReceipt = await backend.addBookmark({ bookId: "b", cfi: "cfi", label: "50%" });
const scratch = mkdtempSync(join(tmpdir(), "reader-annotation-state-"));
try {
  writeFileSync(
    join(scratch, "main.swift"),
    `
import Foundation
${models}
extension Color { init(hex: String) { self = .yellow } }
struct ReaderSelection: Equatable { let text: String; let cfi: String }
struct Reading {
    struct Book { let id = "b" }
    var book: Book? = Book(), cfi = "cfi", fraction = 0.5, chapterTitle = "chapter", dirty = 0
    mutating func markDirty() { dirty += 1 }
}
struct Settings { var highlightColor = "yellow" }
final class Runtime {
    var response = ""
    func appJSONOr(_ expression: String, fallback: String, timeout: Double) -> String { response }
    func appJSON(_ expression: String, timeout: Double) throws -> String? { response }
}
final class Controller {
    var commands: [[String: Any]] = []
    func send(_ command: [String: Any]) { commands.append(command) }
}
final class Reader {
    var reading = Reading(), settings = Settings(), bookmarks: [BookmarkItem] = [], notices: [String] = []
    var selection: ReaderSelection? = ReaderSelection(text: "original", cfi: "cfi")
    let runtime = Runtime(), controller = Controller()
    var syncCalls = 0, loads = 0
    func flash(_ text: String) { notices.append(text) }
    func syncBookmarkPullState() { syncCalls += 1 }
    func loadBookmarks(force: Bool) { loads += 1 }
    func decodeBookmark(_ text: String) -> BookmarkItem? { try? JSONDecoder().decode(BookmarkItem.self, from: Data(text.utf8)) }
    func json(_ value: [String: Any]) -> String { String(decoding: try! JSONSerialization.data(withJSONObject: value), as: UTF8.self) }
${highlight}
${bookmark}
}
var failures = 0, checks = 0
func expect(_ condition: Bool, _ label: String) { checks += 1; if !condition { failures += 1; print("FAIL: " + label) } }
let validHighlight = #"${highlightReceipt}"#
let validBookmark = #"${bookmarkReceipt}"#
for kind in ["highlight", "bookmark"] {
    let valid = kind == "highlight" ? validHighlight : validBookmark
    let invalid = ["", "{}", "null", "not-json", #"{"error":"disk full"}"#,
        valid.replacingOccurrences(of: #""bookId":"b""#, with: #""bookId":"other""#),
        valid.replacingOccurrences(of: #""cfi":"cfi""#, with: #""cfi":"other""#)]
    for response in invalid {
        let probe = Reader(); probe.runtime.response = response
        if kind == "highlight" { probe.saveHighlight(probe.selection!, color: ("yellow", "#facc15")) }
        else { probe.toggleBookmark() }
        expect(probe.reading.dirty == 0 && probe.controller.commands.isEmpty && probe.selection != nil && probe.bookmarks.isEmpty && probe.syncCalls == 0 && probe.loads == 0 && probe.notices.last == (kind == "highlight" ? "高亮没保存上，再试一次" : "书签没保存上，再试一次"), kind + " rejects " + response)
        probe.runtime.response = valid
        if kind == "highlight" {
            probe.saveHighlight(probe.selection ?? ReaderSelection(text: "original", cfi: "cfi"), color: ("yellow", "#facc15"))
            expect(probe.reading.dirty == 1 && probe.selection == nil && probe.controller.commands.count == 2 && probe.notices.last == "已高亮", "highlight successful retry")
        } else {
            probe.toggleBookmark()
            expect(probe.reading.dirty == 1 && probe.bookmarks.count == 1 && probe.syncCalls == 1 && probe.notices.last == "已加书签", "bookmark successful retry")
        }
    }
}
guard failures == 0 else { exit(1) }
print("Reader annotation receipt regression passed (\\(checks) checks)")
`,
  );
  execFileSync(
    "swiftc",
    [
      "-module-cache-path",
      join(scratch, "cache"),
      join(scratch, "main.swift"),
      "-o",
      join(scratch, "test"),
    ],
    { stdio: "inherit" },
  );
  execFileSync(join(scratch, "test"), [], { stdio: "inherit" });
} finally {
  rmSync(scratch, { recursive: true, force: true });
}
