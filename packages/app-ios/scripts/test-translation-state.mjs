#!/usr/bin/env node
// SPDX-License-Identifier: GPL-3.0-or-later
// Exercise the reader's real translation callback with reordered responses.
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const app = process.argv[2] || resolve(dirname(fileURLToPath(import.meta.url)), "..");
const errorMessage = readFileSync(join(app, "Shudeng/Core/AIServiceError.swift"), "utf8");
const source = readFileSync(join(app, "Shudeng/Features/Reader/ReaderScreen.swift"), "utf8");
const method = source
  .slice(source.indexOf("    private func translate("), source.indexOf("    /// 加 / 删当前页书签"))
  .replaceAll("private func ", "func ")
  .replace("{ raw in", "{ [self] raw in");
const scratch = mkdtempSync(join(tmpdir(), "shudeng-translation-"));
try {
  writeFileSync(
    join(scratch, "main.swift"),
    `
import Foundation
${errorMessage}
struct ReaderSelection { let text: String }
struct Settings {
    enum Provider: String { case openai }
    let provider = Provider.openai
    let isConfigured = true
    let baseURL = "mock", apiKey = "mock", model = "mock"
}
final class Runtime {
    var callbacks: [(String) -> Void] = []
    func callAsync(_ expression: String, onResult: @escaping (String) -> Void) {
        callbacks.append(onResult)
    }
}
final class Reader {
    let runtime = Runtime()
    let aiSettings = Settings()
    var translationSource = ""
    var translatedText: String?
    var translationError: String?
    var isTranslating = false
    var showTranslation = false
    var translationGeneration = 0
    func flash(_ text: String) {}
    func json(_ payload: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
    }
${method}
}
var failures = 0
func expect(_ value: Bool, _ message: String) {
    if !value { failures += 1; print("FAIL: " + message) }
}
let reader = Reader()
reader.translate(ReaderSelection(text: "first"))
reader.showTranslation = false
reader.translate(ReaderSelection(text: "second"))
reader.runtime.callbacks[0](#"{"translated":"旧译文"}"#)
expect(reader.isTranslating && reader.translatedText == nil, "旧译文停止新请求 loading 并污染当前选段")
reader.runtime.callbacks[1](#"{"translated":"新译文"}"#)
expect(reader.translationSource == "second" && reader.translatedText == "新译文", "新选段应显示新译文")
reader.runtime.callbacks[0](#"{"error":"旧请求失败"}"#)
expect(reader.translatedText == "新译文", "旧失败覆盖新译文")
for response in [#"{"error":"Connection error."}"#, "invalid", #"{"translated":""}"#, #"{"translated":"  \\n "}"#] {
    let failed = Reader()
    failed.translate(ReaderSelection(text: "数据"))
    failed.runtime.callbacks[0](response)
    expect(failed.translatedText == nil, "失败内容不能作为可复制译文")
    expect(failed.translationError != nil && !failed.isTranslating, "失败需结束loading并显示独立错误")
    expect(failed.showTranslation && failed.translationSource == "数据", "失败后保留原文和弹层")
}
let dismissed = Reader()
dismissed.translate(ReaderSelection(text: "关闭后"))
dismissed.translationGeneration += 1
dismissed.isTranslating = false
dismissed.runtime.callbacks[0](#"{"translated":"迟到译文"}"#)
expect(dismissed.translatedText == nil && !dismissed.isTranslating, "关闭后回调不能写入译文")
let retry = Reader()
retry.translate(ReaderSelection(text: "重试原文"))
retry.runtime.callbacks[0](#"{"error":"Connection error."}"#)
retry.requestTranslation()
expect(retry.isTranslating && retry.translationError == nil && retry.translatedText == nil, "重试清空错误和旧结果")
retry.runtime.callbacks[0](#"{"translated":"旧请求迟到"}"#)
expect(retry.translatedText == nil && retry.isTranslating, "重试期间旧请求不能覆盖新状态")
retry.runtime.callbacks[1](#"{"translated":"Recovered"}"#)
expect(retry.translationSource == "重试原文" && retry.translatedText == "Recovered" && retry.translationError == nil, "重试成功保留原文并恢复可复制译文")
guard failures == 0 else { exit(1) }
print("Translation state regression passed (19 checks)")
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
