#!/usr/bin/env node
// SPDX-License-Identifier: GPL-3.0-or-later
// Compile actual index persistence methods with a failing host; no simulator needed.
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
const app = process.env.READANY_TEST_APP || resolve(dirname(fileURLToPath(import.meta.url)), "..");
const library = readFileSync(join(app, "Shudeng/Features/Library/LibraryStore.swift"), "utf8");
const vector = readFileSync(join(app, "Shudeng/Features/Settings/VectorModelView.swift"), "utf8");
function method(source, name) {
  const start = source.indexOf(`    ${name}`);
  if (start < 0) throw new Error(`Missing method ${name}`);
  const end = source.indexOf("\n    }", start) + 6;
  return source.slice(start, end).replace("private func", "func");
}
const types = library.slice(
  library.indexOf("    struct Book:"),
  library.indexOf("    enum SortField:"),
);
const scratch = mkdtempSync(join(tmpdir(), "shudeng-index-persistence-"));
try {
  const source = join(scratch, "Source.swift");
  writeFileSync(
    source,
    `import Foundation
final class LibraryStore {
${types}
var indexedBooks: [VectorizedBook] = []
var pendingIndexDeletion: Book?
var semanticHits = [SemanticHit(bookId: "b", bookTitle: "Book", chapterIndex: 0, chapterTitle: "chapter", content: "hit", score: 1)]
var indexError: String?, indexingBookId: String? = "b"
var indexingProgress = 0.5, stopped = 0, indexGeneration = 0
func stopIndexPolling() { stopped += 1 }
func refresh(using runtime: RuntimeHost) { refreshIndex(using: runtime) }
static func embeddingInfo(using runtime: RuntimeHost) -> EmbeddingInfo? { nil }
${method(library, "func refreshIndex(")}
${method(library, "func deleteIndex(")}
${method(library, "private func pollIndexStatus(")}
${method(library, "static func payload(")}
}
final class VectorProbe {
let runtime = RuntimeHost()
var info: LibraryStore.EmbeddingInfo?, error: String?
var pendingRemoval: LibraryStore.VectorizedBook?
var books: [LibraryStore.VectorizedBook] = []
${method(vector, "private func load(")}
${method(vector, "private func remove(")}
}
`,
  );
  const executable = join(scratch, "test");
  execFileSync(
    "swiftc",
    [
      "-module-cache-path",
      join(scratch, "cache"),
      source,
      process.env.READANY_TEST_FIXTURE || join(app, "Tests/IndexPersistenceStateTests.swift"),
      "-o",
      executable,
    ],
    { stdio: "inherit" },
  );
  execFileSync(executable, [], { stdio: "inherit" });
} finally {
  rmSync(scratch, { recursive: true, force: true });
}
