#!/usr/bin/env node
import { execFileSync } from "node:child_process";
// SPDX-License-Identifier: GPL-3.0-or-later
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
const app = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const source = readFileSync(join(app, "Shudeng/Features/Stats/ReadingInsightsView.swift"), "utf8");
const method = source
  .slice(
    source.indexOf("    private func generate(_ payload: ReportPayload)"),
    source.indexOf("    /// 只把模型真正需要的数字给它"),
  )
  .replace("private func generate", "func generate")
  .replace("{ result in", "{ [self] result in");
const scratch = mkdtempSync(join(tmpdir(), "report-state-"));
process.on("exit", () => rmSync(scratch, { recursive: true, force: true }));
const harness = `
import Foundation
struct ReportPayload {}
enum ReadingReportRange { case week, month }
struct Settings { enum Provider: String { case openai }; let provider = Provider.openai; let isConfigured = true; let apiKey = "fixture", baseURL = "fixture", model = "fixture" }
final class Runtime { var callbacks: [(String)->Void] = []; func callAsync(_ expression:String,timeout:Double,onResult:@escaping(String)->Void) { callbacks.append(onResult) } }
final class Report {
let runtime = Runtime(), aiSettings = Settings()
var range = ReadingReportRange.week
var aiError: String?
var aiText: [ReadingReportRange:String] = [:]
var isGenerating = false
func aiPrompt(_ payload:ReportPayload)->String { "fixture" }
${method}
}
var failures = 0
func expect(_ condition:Bool,_ text:String) { if !condition { failures += 1; print("FAIL: " + text) } }
for response in [#"{"error":"week failure"}"#, "invalid", #"{"text":""}"#] {
let report = Report()
report.generate(ReportPayload())
report.range = .month
report.runtime.callbacks[0](response)
expect(report.aiError == nil && !report.isGenerating,"failure from another range must not appear in month")
report.generate(ReportPayload())
report.runtime.callbacks[1](#"{"error":"month failure"}"#)
expect(report.aiError == "解读失败：month failure", "current range failure must remain visible")
}
let report = Report()
report.generate(ReportPayload())
report.range = .month
report.runtime.callbacks[0](#"{"text":"week report"}"#)
expect(report.aiText[.week] == "week report" && report.aiText[.month] == nil,"success must stay cached under requested range")
guard failures == 0 else { exit(1) }
print("Report state regression passed (7 checks)")
`;
writeFileSync(join(scratch, "main.swift"), harness);
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
