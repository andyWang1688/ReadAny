#!/usr/bin/env node
import { execFileSync } from "node:child_process";
// SPDX-License-Identifier: GPL-3.0-or-later
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
const app = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const source = readFileSync(join(app, "Shudeng/Features/Chat/MermaidDiagramView.swift"), "utf8");
const method = source
  .slice(
    source.indexOf("    private var cacheKey:"),
    source.indexOf("/// 同一段图表别每滚一次就重画一遍。"),
  )
  .replace(/\n}\n\n$/, "\n")
  .replace("private func render()", "func render()")
  .replace("{ raw in", "{ [self] raw in");
const cache = source.slice(source.indexOf("@MainActor\nfinal class MermaidSVGCache"));
const scratch = mkdtempSync(join(tmpdir(), "mermaid-state-"));
process.on("exit", () => rmSync(scratch, { recursive: true, force: true }));
writeFileSync(
  join(scratch, "Test.swift"),
  `
import Foundation
final class Runtime { var callbacks: [(String)->Void] = []; func callAsync(_ expression:String,timeout:Double,onResult:@escaping(String)->Void) { callbacks.append(onResult) } }
enum Scheme { case dark, light }
@MainActor final class Block {
var source = "graph TD; A-->B", streaming = false, colorScheme = Scheme.dark
let runtime = Runtime()
var svg: String?, failed = false, renderGeneration = 0
${method}
}
${cache}
@main struct Tests {
@MainActor static func main() {
var failures = 0
func expect(_ condition:Bool,_ text:String) { if !condition { failures += 1; print("FAIL: " + text) } }
MermaidSVGCache.shared.store("LIGHT-CACHED",for:"light|false|graph TD; A-->B")
let block = Block()
block.render()
block.colorScheme = .light
block.render()
block.runtime.callbacks[0](#"{"svg":"DARK-STALE"}"#)
expect(block.svg == "LIGHT-CACHED", "queued old result must not replace a new cache hit")
block.runtime.callbacks[0](#"{"error":"old failure"}"#)
expect(!block.failed, "old failure must not mark new cache hit as failed")
let streaming = Block()
streaming.render()
streaming.streaming = true
streaming.render()
streaming.runtime.callbacks[0](#"{"svg":"STALE-SOURCE"}"#)
expect(streaming.svg == nil, "old result must not replace a streaming source")
let fresh = Block()
fresh.source = "fresh"
fresh.render()
fresh.runtime.callbacks[0](#"{"svg":"FRESH"}"#)
expect(fresh.svg == "FRESH" && !fresh.failed, "current result must render")
guard failures == 0 else { exit(1) }
print("Mermaid state regression passed (4 checks)")
}
}
`,
);
execFileSync(
  "swiftc",
  [
    "-parse-as-library",
    "-module-cache-path",
    join(scratch, "cache"),
    join(scratch, "Test.swift"),
    "-o",
    join(scratch, "test"),
  ],
  { stdio: "inherit" },
);
execFileSync(join(scratch, "test"), [], { stdio: "inherit" });
