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
const comparison = source.slice(source.indexOf("struct ReportComparison:"), source.indexOf("struct ReportPayload:"));
const deltaMethod = source.slice(source.indexOf("    private func deltaText("), source.indexOf("    /// 同一年只写一次年份")).replace("private func deltaText", "func deltaText");
const scratch = mkdtempSync(join(tmpdir(), "report-state-"));
process.on("exit", () => rmSync(scratch, { recursive: true, force: true }));
const harness = `
import Foundation
${comparison}
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
${deltaMethod}
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
let growth = ReportComparison(label: "readingTime", value: 40, delta: 1359, deltaLabel: "+1359%")
expect(report.deltaText(growth) == "增加 1359%", "report must show percentage units for growth")
let first = ReportComparison(label: "readingTime", value: 10, delta: 100, deltaLabel: "+∞")
expect(report.deltaText(first) == "上期为 0", "zero baseline cannot be shown as 100 percent growth")
let decline = ReportComparison(label: "activeDays", value: 2, delta: -50, deltaLabel: "-50%")
expect(report.deltaText(decline) == "减少 50%", "negative comparison must remain clear")
expect(report.deltaText(ReportComparison(label: "sessions", value: 2, delta: 0, deltaLabel: "—")) == "持平", "zero change should read as unchanged")
expect(growth.displayName == "阅读时长" && growth.formattedValue == "40 分钟", "reading duration label and units must be readable")
expect(decline.displayName == "阅读天数" && decline.formattedValue == "2 天", "active days require day units")
for (key, title, unit) in [("sessions", "阅读次数", "次"), ("books", "读过的书", "本"), ("avgSessionTime", "平均单次时长", "分钟")] {
let metric = ReportComparison(label: key, value: 3, delta: nil, deltaLabel: "")
expect(metric.displayName == title && metric.formattedValue == "3 " + unit, "all comparison metrics must use reader-facing labels and units")
}
guard failures == 0 else { exit(1) }
print("Report state regression passed (16 checks)")
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
