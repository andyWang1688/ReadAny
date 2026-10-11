#!/usr/bin/env node
import { execFileSync } from "node:child_process";
// SPDX-License-Identifier: GPL-3.0-or-later
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
const app = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const models = readFileSync(join(app, "Shudeng/Features/Notes/NotesView.swift"), "utf8").split(
  "@MainActor\nfinal class NotesStore",
)[0];
const source = readFileSync(join(app, "Shudeng/Features/Reader/ReaderScreen.swift"), "utf8");
const method = source
  .slice(
    source.indexOf("    private func saveNote()"),
    source.indexOf("    /// 选中文本翻译", source.indexOf("    private func saveNote()")),
  )
  .replace("private func saveNote()", "func saveNote()");
const open = source
  .slice(
    source.indexOf("                    if noteTarget != selection"),
    source.indexOf('                .accessibilityIdentifier("reader.selectionNote")'),
  )
  .split("                } label:")[0];
const scratch = mkdtempSync(join(tmpdir(), "reader-note-state-"));
process.on("exit", () => rmSync(scratch, { recursive: true, force: true }));
const drafts = readFileSync(join(app, "Shudeng/Core/NoteDrafts.swift"), "utf8").replace(
  /FileManager.default.urls\(for: \.documentDirectory, in: \.userDomainMask\)\[0\]\s*\.appendingPathComponent\("unsaved-notes", isDirectory: true\)/,
  'URL(fileURLWithPath: ' + JSON.stringify(join(scratch, "drafts")) + ')',
);
const draftMethods = source.slice(source.indexOf("    private func restoreNoteDraft("), source.indexOf("    private func deleteAnnotation("));
writeFileSync(
  join(scratch, "main.swift"),
  `
import Foundation
${drafts}
struct ReaderSelection:Equatable { let text:String; let cfi:String }
${models}
extension Color { init(hex:String) { self = .yellow } }
struct Reading { struct Book { let id = "b" }; var book:Book? = Book(); var chapterTitle = "chapter"; var dirty = 0; mutating func markDirty() { dirty += 1 } }
struct Settings { let highlightColor = "yellow" }
final class Runtime { var response = ""; func appJSONOr(_ expression:String,fallback:String,timeout:Double)->String { response } }
final class Controller { var commands:[[String:Any]] = []; func send(_ value:[String:Any]) { commands.append(value) } }
final class Reader {
var reading = Reading(), settings = Settings()
let runtime = Runtime(), controller = Controller()
var selection:ReaderSelection? = ReaderSelection(text:"original",cfi:"cfi")
var editingAnnotation:HighlightItem?
var noteTarget:ReaderSelection?, noteDraft = "", noteOriginal = "", noteDraftRestored = false, noteDraftError:String?, showNoteEditor = false, noteError:String?
let highlightColors = [(name:"yellow",hex:"#facc15")]
func json(_ payload:[String:Any])->String { String(decoding:try! JSONSerialization.data(withJSONObject:payload),as:UTF8.self) }
func flash(_ text:String) {}
func openEditor() { guard let selection else { return }; ${open} }
${draftMethods}
${method}
}
var failures = 0
func expect(_ condition:Bool,_ text:String) { if !condition { failures += 1; print("FAIL: " + text) } }
let reader = Reader()
reader.openEditor()
reader.noteDraft = "draft survives"
reader.saveNote()
expect(reader.showNoteEditor && reader.noteDraft == "draft survives" && reader.noteTarget != nil && reader.noteError != nil,"save failure must retain visible editor/draft/target")
reader.showNoteEditor = false
reader.openEditor()
expect(reader.noteDraft == "draft survives", "reopen same selection must retain failed draft")
for response in ["{}", #"{"id":"h","bookId":"wrong","cfi":"cfi","text":"original","color":"yellow","createdAt":1}"#] {
reader.runtime.response = response
reader.saveNote()
expect(reader.showNoteEditor && reader.reading.dirty == 0 && reader.controller.commands.isEmpty,"invalid receipt must not acknowledge save")
}
reader.runtime.response = #"{"id":"h","bookId":"b","cfi":"cfi","text":"original","color":"yellow","createdAt":1}"#
reader.saveNote()
expect(!reader.showNoteEditor && reader.noteDraft.isEmpty && reader.noteTarget == nil && reader.noteError == nil && reader.reading.dirty == 1,"successful retry must persist annotation and dismiss editor")
guard failures == 0 else { exit(1) }
print("Reader note state regression passed (5 checks)")
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
