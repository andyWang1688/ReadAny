#!/usr/bin/env node
// SPDX-License-Identifier: GPL-3.0-or-later
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
const app = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const source = readFileSync(join(app, "Shudeng/Features/Reader/ReaderScreen.swift"), "utf8");
const models = readFileSync(join(app, "Shudeng/Features/Notes/NotesView.swift"), "utf8").split(
  "@MainActor\nfinal class NotesStore",
)[0];
function method(start, end) {
  const i = source.indexOf(start);
  return i < 0 ? "" : source.slice(i, source.indexOf(end, i)).replace("private func", "func");
}
const handle = method("    private func handle(event:", "    private func loadAnnotations()");
const annotationCases =
  handle.match(/ {8}case "show-annotation":[\s\S]*?(?= {8}case "selection":)/)?.[0] || "";
const open = method("    private func showAnnotation(", "    private func deleteAnnotation()");
const remove = method("    private func deleteAnnotation()", "    private func saveNote()");
const save = method("    private func saveNote()", "    /// 选中文本翻译");
const scratch = mkdtempSync(join(tmpdir(), "reader-existing-annotation-"));
try {
  writeFileSync(
    join(scratch, "main.swift"),
    `
import Foundation
${models}
extension Color { init(hex:String) { self = .yellow } }
struct ReaderSelection:Equatable { let text:String; let cfi:String }
struct Reading { struct Book { let id="b" }; var book:Book?=Book(); var chapterTitle="chapter",dirty=0; mutating func markDirty(){dirty += 1} }
struct Settings { var highlightColor="yellow" }
final class Runtime { var response="", rows="[]", calls:[String]=[]; func appJSONOr(_ expression:String,fallback:String,timeout:Double)->String { calls.append(expression); return expression.contains("listHighlights") ? rows : response } }
final class Controller { var commands:[[String:Any]]=[]; func send(_ command:[String:Any]){commands.append(command)} }
final class Reader {
 var reading=Reading(),settings=Settings(); let runtime=Runtime(),controller=Controller()
 var selection:ReaderSelection?,noteTarget:ReaderSelection?,editingAnnotation:HighlightItem?,noteDraft="",noteError:String?,showNoteEditor=false
 var notices:[String]=[]; let highlightColors=[(name:"yellow",hex:"#facc15"),(name:"pink",hex:"#f472b6")]
 func flash(_ text:String){notices.append(text)}
 func loadAnnotations() {}
 func json(_ value:[String:Any])->String{String(decoding:try! JSONSerialization.data(withJSONObject:value),as:UTF8.self)}
 func handle(event:[String:Any]) { guard let type=event["type"] as? String else{return}; switch type {
${annotationCases}
 default:break
 } }
${open}
${remove}
${save}
}
let row = #"{"id":"h","bookId":"b","cfi":"cfi","text":"original","color":"pink","note":"existing","createdAt":1}"#
var failures=0,checks=0
func expect(_ condition:Bool,_ text:String){checks += 1;if !condition {failures += 1;print("FAIL: "+text)}}
let reader=Reader();reader.runtime.rows="["+row+"]"
reader.handle(event:["type":"show-annotation","value":"cfi"])
expect(reader.showNoteEditor && reader.noteTarget?.text=="original" && reader.noteDraft=="existing" && reader.editingAnnotation?.id=="h","tap must open existing original/note")
if !reader.showNoteEditor { exit(1) }
reader.noteDraft="edited"
reader.runtime.response="{}";reader.saveNote()
expect(reader.showNoteEditor && reader.noteDraft=="edited" && reader.reading.dirty==0 && reader.controller.commands.isEmpty,"update failure preserves editor/draft")
reader.runtime.response="ok";reader.saveNote()
expect(!reader.showNoteEditor && reader.reading.dirty==1 && reader.editingAnnotation==nil,"update success closes editor")
expect(reader.runtime.calls.contains(where:{$0.contains("updateHighlight") && $0.contains("edited")}) && !reader.runtime.calls.contains(where:{$0.contains("addHighlight")}),"edit updates existing ID without inserting duplicate")
let annotation=reader.controller.commands.first?["annotation"] as? [String:Any]
expect(annotation?["color"] as? String == "#f472b6" && annotation?["note"] as? String == "edited","edit keeps original highlight color")
reader.handle(event:["type":"note-tooltip","cfi":"cfi"])
expect(reader.showNoteEditor && reader.noteDraft=="existing","long press reads persisted note")
reader.runtime.response="{}";reader.deleteAnnotation()
expect(reader.showNoteEditor && reader.editingAnnotation != nil && reader.reading.dirty==1,"delete failure preserves editor")
reader.runtime.response="ok";reader.deleteAnnotation()
expect(!reader.showNoteEditor && reader.reading.dirty==2 && reader.controller.commands.contains(where:{$0["type"] as? String == "removeAnnotation"}),"delete success removes visible annotation")
reader.handle(event:["type":"show-annotation","value":"missing"])
expect(!reader.showNoteEditor,"unknown CFI must not open stale editor")
reader.runtime.rows="not-json";reader.handle(event:["type":"show-annotation","value":"cfi"])
expect(!reader.showNoteEditor,"failed lookup must not open stale editor")
guard failures==0 else{exit(1)}
print("Existing reader annotation regression passed (\\(checks) checks)")
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
