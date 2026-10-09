#!/usr/bin/env node
// SPDX-License-Identifier: GPL-3.0-or-later
// Replay out-of-order responses against the actual sheet generation method.
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const app = resolve(process.argv[2] || "packages/app-ios");
const source = readFileSync(join(app, "Shudeng/Features/Chat/MindMapView.swift"), "utf8");
const outline = source.slice(
  source.indexOf("struct MindNode:"),
  source.indexOf("/// 思维导图排版"),
);
const generate = source
  .slice(source.indexOf("    private func generate()"), source.lastIndexOf("\n}"))
  .replace("private func generate()", "func generate()")
  .replace("{ raw in", "{ [self] raw in");
const scratch = mkdtempSync(join(tmpdir(), "shudeng-mindmap-state-"));
try {
  writeFileSync(
    join(scratch, "main.swift"),
    `
import Foundation
${outline}
final class Runtime {
    var responses: [(String) -> Void] = []
    func callAsync(_ expression: String, timeout: Double, onResult: @escaping (String) -> Void) {
        responses.append(onResult)
    }
}
struct Book { let id = "book"; let title = "书"; let author = "作者" }
struct Reading {
    var book: Book? = Book()
    var chapterText = String(repeating: "章", count: 60)
    var visibleText = String(repeating: "页", count: 60)
    var chapterTitle = "本章"
}
struct Settings {
    enum Provider: String { case openai }
    var provider = Provider.openai
    var isConfigured = true
    var baseURL = "mock", apiKey = "mock", model = "mock"
}
final class Sheet {
    enum Scope { case chapter, page }
    enum Phase { case loading, ready(MindNode), failed(String) }
    var bookId: String? = "book"
    var reading = Reading()
    var aiSettings = Settings()
    var runtime = Runtime()
    var scope = Scope.chapter
    var phase = Phase.loading
    var outline = ""
    var copied = false
    var generation = 0
${generate}
}
var failures = 0
func expect(_ condition: Bool, _ message: String) {
    if !condition { failures += 1; print("FAIL: " + message) }
}
let sheet = Sheet()
sheet.generate()
sheet.scope = .page
sheet.generate()
sheet.runtime.responses[1](##"{"text":"# 最新页\\n- 要点"}"##)
sheet.runtime.responses[0](##"{"text":"# 旧章节\\n- 要点"}"##)
expect(sheet.outline.contains("最新页"), "旧成功覆盖了新结果")
sheet.generate()
expect(sheet.outline.isEmpty, "新生成期间复制按钮仍能复制旧大纲")
sheet.generate()
sheet.runtime.responses[3](##"{"text":"# 最新重试\\n- 要点"}"##)
sheet.runtime.responses[2](##"{"error":"旧请求超时"}"##)
if case .ready = sheet.phase {} else { expect(false, "旧失败覆盖了最新成功") }
sheet.generate()
sheet.reading.visibleText = ""
sheet.generate()
sheet.runtime.responses[4](##"{"text":"# 失效页\\n- 要点"}"##)
if case .failed = sheet.phase {} else { expect(false, "新范围校验失败后旧结果仍被接受") }
guard failures == 0 else { exit(1) }
print("Mind-map state regression passed (4 scenarios)")
`,
  );
  execFileSync(
    "swiftc",
    [
      "-module-cache-path",
      join(scratch, "modulecache"),
      join(scratch, "main.swift"),
      "-o",
      join(scratch, "probe"),
    ],
    { stdio: "inherit" },
  );
  execFileSync(join(scratch, "probe"), [], { stdio: "inherit" });
} finally {
  rmSync(scratch, { recursive: true, force: true });
}
