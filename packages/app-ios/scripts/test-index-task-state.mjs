#!/usr/bin/env node
// SPDX-License-Identifier: GPL-3.0-or-later
// Replay main-queue results against the actual LibraryStore index methods.
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const app = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const library = readFileSync(join(app, "Shudeng/Features/Library/LibraryStore.swift"), "utf8");
function method(name) {
  const start = library.indexOf(`    ${name}`);
  if (start < 0) throw new Error(`Missing method ${name}`);
  const end = library.indexOf("\n    }", start) + 6;
  return library.slice(start, end).replace("private func", "func");
}
const types = library.slice(
  library.indexOf("    struct Book:"),
  library.indexOf("    enum SortField:"),
);
const methods = [
  "func buildIndex(",
  "func deleteIndex(",
  "func refreshIndex(",
  "private func startIndexPolling(",
  "private func stopIndexPolling(",
  "private func pollIndexStatus(",
  "static func payload(",
  "static func errorMessage(",
]
  .map(method)
  .join("\n");
const scratch = mkdtempSync(join(tmpdir(), "shudeng-index-task-state-"));
try {
  const source = join(scratch, "LibraryStore.swift");
  writeFileSync(
    source,
    `import Foundation\n@MainActor final class LibraryStore {\n${types}var indexedBooks: [VectorizedBook] = [], semanticHits: [SemanticHit] = []\nvar indexingBookId: String?, indexError: String?, indexTimer: Timer?\nvar pendingIndexDeletion: Book?\nvar indexingProgress = 0.0, indexGeneration = 0\nfunc refresh(using runtime: RuntimeHost) { refreshIndex(using: runtime) }\n${methods}\n}\n`,
  );
  const executable = join(scratch, "test");
  execFileSync(
    "swiftc",
    [
      "-module-cache-path",
      join(scratch, "cache"),
      source,
      join(app, "Tests/IndexTaskStateTests.swift"),
      "-o",
      executable,
    ],
    { stdio: "inherit" },
  );
  execFileSync(executable, [], { stdio: "inherit" });
} finally {
  rmSync(scratch, { recursive: true, force: true });
}
