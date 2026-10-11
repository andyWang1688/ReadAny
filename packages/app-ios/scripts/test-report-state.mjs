#!/usr/bin/env node
import { execFileSync } from "node:child_process";
// SPDX-License-Identifier: GPL-3.0-or-later
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
const app = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const durationFormat = readFileSync(join(app, "Shudeng/DesignSystem/ReadingDuration.swift"), "utf8");
const errorMessage = readFileSync(join(app, "Shudeng/Core/AIServiceError.swift"), "utf8");
const state = readFileSync(join(app, "Shudeng/Features/Stats/ReportAIStore.swift"), "utf8")
  .replace("import SwiftUI", "")
  .replace("@MainActor\n", "")
  .replace("final class ReportAIStore: ObservableObject", "final class ReportAIStore")
  .replaceAll("@Published ", "");
const source = readFileSync(join(app, "Shudeng/Features/Stats/ReadingInsightsView.swift"), "utf8");
const method = source
  .slice(
    source.indexOf("    private func generate(_ payload: ReportPayload)"),
    source.indexOf("    /// 只把模型真正需要的数字给它"),
  )
  .replace("private func generate", "func generate")
  .replace("{ result in", "{ [self] result in");
const models = source.slice(source.indexOf("struct ReportPeriod:"), source.indexOf("@MainActor\nfinal class ReportStore"));
const promptMethod = source.slice(source.indexOf("    private func aiPrompt("), source.indexOf("    private func deltaText(")).replace("private func aiPrompt", "func aiPrompt");
const deltaMethod = source.slice(source.indexOf("    private func deltaText("), source.indexOf("    /// 同一年只写一次年份")).replace("private func deltaText", "func deltaText");
const scratch = mkdtempSync(join(tmpdir(), "report-state-"));
process.on("exit", () => rmSync(scratch, { recursive: true, force: true }));
const harness = `
import Foundation
${errorMessage}
${durationFormat}
${models}
${state}
let testRoot = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
extension ReportPayload {
    init(range: ReadingReportRange = .week) {
        self.init(
            dimension: range.rawValue,
            period: ReportPeriod(dimension: range.rawValue, key: range == .week ? "2026-W41" : range == .month ? "2026-10" : "lifetime", startDate: range == .week ? "2026-10-05" : "2026-10-01", endDate: range == .week ? "2026-10-11" : "2026-10-31", label: range.rawValue),
            summary: ReportSummary(totalReadingTime: 71.5137, totalSessions: 130, totalPagesRead: 248, activeDays: 4, booksTouched: 3, completedBooks: 0, avgSessionTime: 0.5501053846, longestSessionTime: 6.6540666667, currentStreak: 4, longestStreak: 4),
            topBooks: [ReportTopBook(bookId: "ui-test-sample-pdf", title: "合成PDF", author: "", totalTime: 0.4011166667, pagesRead: 1, progress: 0.33)],
            previous: [ReportComparison(label: "avgSessionTime", value: 0.5501053846, delta: -60, deltaLabel: "-60%")]
        )
    }
}
struct Settings { enum Provider: String { case openai }; let provider = Provider.openai; let isConfigured = true; let apiKey = "fixture", baseURL = "fixture", model = "fixture" }
typealias AISettings = Settings
final class Runtime {
    var callbacks: [(String)->Void] = []
    let rootDirectory: URL
    init(rootDirectory: URL = testRoot.appendingPathComponent(UUID().uuidString)) { self.rootDirectory = rootDirectory }
    func callAsync(_ expression:String,timeout:Double,onResult:@escaping(String)->Void) { callbacks.append(onResult) }
}
typealias RuntimeHost = Runtime
final class Report {
let runtime: Runtime, aiSettings = Settings(), aiStore = ReportAIStore()
init(rootDirectory: URL = testRoot.appendingPathComponent(UUID().uuidString)) {
    runtime = Runtime(rootDirectory: rootDirectory)
    aiStore.load(from: rootDirectory)
}
var range = ReadingReportRange.week
var aiError: String? { aiStore.error(for: ReportPayload(range: range)) }
var aiText: [ReadingReportRange: String] {
    Dictionary(uniqueKeysWithValues: ReadingReportRange.allCases.compactMap { item in
        aiStore.text(for: ReportPayload(range: item)).map { (item, $0) }
    })
}
var isGenerating: Bool { aiStore.isGenerating }
${promptMethod}
${method}
${deltaMethod}
}
var failures = 0, checks = 0
func expect(_ condition:Bool,_ text:String) { checks += 1; if !condition { failures += 1; print("FAIL: " + text) } }
for response in [#"{"error":"week failure"}"#, "invalid", #"{"text":""}"#] {
let report = Report()
report.generate(ReportPayload(range: report.range))
report.range = .month
report.runtime.callbacks[0](response)
expect(report.aiError == nil && !report.isGenerating,"failure from another range must not appear in month")
report.generate(ReportPayload(range: report.range))
report.runtime.callbacks[1](#"{"error":"month failure"}"#)
expect(report.aiError == "AI 服务返回错误：month failure", "current range failure must remain visible")
}
let report = Report()
report.generate(ReportPayload(range: report.range))
report.range = .month
report.runtime.callbacks[0](#"{"text":"week report"}"#)
expect(report.aiText[.week] == "week report" && report.aiText[.month] == nil,"success must stay cached under requested range")
let growth = ReportComparison(label: "readingTime", value: 40, delta: 1359, deltaLabel: "+1359%")
expect(report.deltaText(growth) == "约为上期 15 倍", "large growth should show current-to-previous ratio, including the baseline")
expect(report.deltaText(ReportComparison(label: "readingTime", value: 71.5137, delta: 2476, deltaLabel: "+2476%")) == "约为上期 26 倍", "actual weekly growth must read as about 26 times the previous week")
expect(report.deltaText(ReportComparison(label: "readingTime", value: 11, delta: 1000, deltaLabel: "+1000%")) == "约为上期 11 倍", "large-growth boundary must include baseline")
expect(report.deltaText(ReportComparison(label: "readingTime", value: 10.99, delta: 999, deltaLabel: "+999%")) == "增加 999%", "growth below threshold must keep percentage units")
expect(report.deltaText(ReportComparison(label: "readingTime", value: 3, delta: 50, deltaLabel: "+50%")) == "增加 50%", "ordinary positive growth must remain a percentage")
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
let recovery = Report()
recovery.generate(ReportPayload())
recovery.generate(ReportPayload())
expect(recovery.runtime.callbacks.count == 1, "generating report must reject duplicate requests")
recovery.runtime.callbacks[0](#"{"error":"Connection error."}"#)
expect(recovery.aiError == "无法连接 AI 服务，请检查网络或服务地址后重试。", "connection failure must explain recovery in Chinese")
expect(recovery.aiText[.week] == nil && !recovery.isGenerating, "failure must not create report text or stay loading")
recovery.generate(ReportPayload())
expect(recovery.aiError == nil && recovery.isGenerating, "retry must clear error and show loading")
recovery.runtime.callbacks.last!(#"{"text":"recovered"}"#)
expect(recovery.aiText[.week] == "recovered" && !recovery.isGenerating, "retry must recover usable report text")
recovery.generate(ReportPayload())
expect(recovery.aiText[.week] == "recovered" && recovery.isGenerating, "regeneration must keep existing report while loading")
recovery.runtime.callbacks.last!(#"{"error":"Connection error."}"#)
expect(recovery.aiText[.week] == "recovered" && recovery.aiError != nil && !recovery.isGenerating, "failed regeneration must preserve existing report")
recovery.generate(ReportPayload())
recovery.runtime.callbacks.last!(#"{"text":"   "}"#)
expect(recovery.aiText[.week] == "recovered" && recovery.aiError == "没有收到有效解读，请重试。", "blank response must preserve report and allow retry")
let short = ReportComparison(label: "avgSessionTime", value: 0.5501053846153846, delta: nil, deltaLabel: "")
expect(short.formattedValue == "<1 分钟", "positive sub-minute session must not claim zero or one minute")
expect(ReportComparison(label: "readingTime", value: 71.5137, delta: nil, deltaLabel: "").formattedValue == "72 分钟", "actual weekly source must round to 72 minutes")
expect(ReportComparison(label: "readingTime", value: 0, delta: nil, deltaLabel: "").formattedValue == "0 分钟", "no reading must remain zero")
expect(ReadingDuration.minutesValue(71.5137) == "72", "stat and report minute numbers share actual weekly rounding")
expect(ReadingDuration.minutes(0.4011166667) == "<1 分钟", "24-second sample book remains visible as positive duration")
expect(ReadingDuration.minutes(6.6540667) == "7 分钟", "longest session uses the same rounding rule")
let prompt = report.aiPrompt(ReportPayload())
expect(prompt.contains("平均每次 <1 分钟") && prompt.contains("平均单次时长 <1 分钟"), "actual AI prompt must agree with comparison for sub-minute average")
expect(prompt.contains("最长一次 7 分钟") && prompt.contains("合成PDF（<1 分钟）"), "actual AI prompt must share page duration formatting")

let restored = Report(rootDirectory: report.runtime.rootDirectory)
expect(restored.aiText[.week] == "week report", "a fresh page/store must restore the completed weekly interpretation from disk")
expect(restored.aiText[.month] == nil && restored.aiText[.lifetime] == nil, "disk restoration must not leak week text into month or lifetime")
let weekly = ReportPayload()
let nextWeek = ReportPayload(dimension: "week", period: ReportPeriod(dimension: "week", key: "2026-W42", startDate: "2026-10-12", endDate: "2026-10-18", label: "week"), summary: weekly.summary, topBooks: weekly.topBooks, previous: weekly.previous)
expect(restored.aiStore.text(for: nextWeek) == nil, "a new week must not display the previous week's interpretation")
let changed = ReportPayload(dimension: weekly.dimension, period: weekly.period, summary: weekly.summary, topBooks: [], previous: weekly.previous)
restored.range = .week
expect(!restored.aiStore.isOutdated(for: weekly, source: restored.aiPrompt(weekly)), "unchanged reading data must retain a current interpretation")
expect(restored.aiStore.isOutdated(for: changed, source: restored.aiPrompt(changed)) && restored.aiStore.text(for: changed) == "week report", "changed reading data must preserve old text and mark it outdated")
report.generate(ReportPayload(range: .month))
expect(report.aiStore.isGenerating(for: ReportPayload(range: .month)) && !report.aiStore.isGenerating(for: weekly), "pending generation must be scoped to the requested period")
report.runtime.callbacks.last!(#"{"text":"month report"}"#)
let both = Report(rootDirectory: report.runtime.rootDirectory)
expect(both.aiText[.week] == "week report" && both.aiText[.month] == "month report", "saving month must preserve the separate weekly result on disk")
let stableURL = report.runtime.rootDirectory.appendingPathComponent("reading-report-ai.json")
let stableData = try Data(contentsOf: stableURL)
report.generate(ReportPayload(range: .month))
report.runtime.callbacks.last!(#"{"error":"Connection error."}"#)
expect(try Data(contentsOf: stableURL) == stableData, "failed regeneration must not overwrite the last saved result")
expect(!(String(data: stableData, encoding: .utf8) ?? "").contains("fixture") && !(String(data: stableData, encoding: .utf8) ?? "").contains("apiKey"), "cache must never persist request credentials or endpoint settings")
let departedRuntime = Runtime()
var departed: ReportAIStore? = ReportAIStore()
departed?.generate(weekly, prompt: "合成阅读记录", using: departedRuntime, settings: Settings())
departed = nil
let finish = departedRuntime.callbacks.removeFirst()
finish(#"{"text":"completed after departure"}"#)
let afterDeparture = Report(rootDirectory: departedRuntime.rootDirectory)
expect(afterDeparture.aiText[.week] == "completed after departure", "a callback after page departure must complete local persistence")
let blockedRoot = testRoot.appendingPathComponent("blocked-parent")
try Data("blocks directory creation".utf8).write(to: blockedRoot)
let blocked = Report(rootDirectory: blockedRoot)
blocked.generate(weekly)
blocked.runtime.callbacks.last!(#"{"text":"unsaved report"}"#)
expect(blocked.aiText[.week] == "unsaved report" && blocked.aiStore.persistenceError != nil, "disk failure must preserve usable in-memory text and show a save error")
try FileManager.default.removeItem(at: blockedRoot)
blocked.aiStore.retrySave()
let afterRetry = Report(rootDirectory: blockedRoot)
expect(blocked.aiStore.persistenceError == nil && afterRetry.aiText[.week] == "unsaved report", "retry save must persist existing text without a new AI request")
expect(blocked.runtime.callbacks.count == 1, "retry save must not request AI again")
let corruptRoot = testRoot.appendingPathComponent("corrupt-cache")
try FileManager.default.createDirectory(at: corruptRoot, withIntermediateDirectories: true)
let corruptURL = corruptRoot.appendingPathComponent("reading-report-ai.json")
let corruptData = Data("{broken-original".utf8)
try corruptData.write(to: corruptURL)
let corrupt = Report(rootDirectory: corruptRoot)
corrupt.generate(weekly)
corrupt.runtime.callbacks.last!(#"{"text":"new unsaved report"}"#)
expect(try Data(contentsOf: corruptURL) == corruptData, "an unreadable existing cache must be preserved rather than silently overwritten")
expect(corrupt.aiText[.week] == "new unsaved report" && corrupt.aiStore.persistenceError != nil, "unreadable storage must be visible while retaining the new result in memory")

guard failures == 0 else { exit(1) }
print("Report state regression passed (\\(checks) checks)")
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
execFileSync(join(scratch, "test"), [scratch], { stdio: "inherit" });
