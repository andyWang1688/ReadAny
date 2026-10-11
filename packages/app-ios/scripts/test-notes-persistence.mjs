#!/usr/bin/env node
// SPDX-License-Identifier: GPL-3.0-or-later
// Exercise the actual NotesStore and reader bookmark mutation with failing host writes.
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const app = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const notes = readFileSync(join(app, "Shudeng/Features/Notes/NotesView.swift"), "utf8");
const reader = readFileSync(join(app, "Shudeng/Features/Reader/ReaderScreen.swift"), "utf8");
const store = notes.slice(0, notes.indexOf("struct NotesView: View"));
const toggle = reader
  .slice(
    reader.indexOf("    private func toggleBookmark()"),
    reader.indexOf("    /// 把「当前页是否已加书签」"),
  )
  .replace("private func toggleBookmark()", "func toggleBookmark()");
const fixture = readFileSync(join(app, "Tests/ReaderBookmarkFixture.swift"), "utf8");
const scratch = mkdtempSync(join(tmpdir(), "shudeng-notes-persistence-"));
try {
  const drafts = readFileSync(join(app, "Shudeng/Core/NoteDrafts.swift"), "utf8").replace(
    /FileManager.default.urls\(for: \.documentDirectory, in: \.userDomainMask\)\[0\]\s*\.appendingPathComponent\("unsaved-notes", isDirectory: true\)/,
    'URL(fileURLWithPath: ' + JSON.stringify(join(scratch, "drafts")) + ')',
  );
  const source = join(scratch, "Source.swift");
  const executable = join(scratch, "test");
  writeFileSync(
    source,
    `${drafts}\n${store}\n@MainActor final class ReaderProbe {\n${fixture}\n${toggle}\n}\n`,
  );
  execFileSync(
    "swiftc",
    [
      "-module-cache-path",
      join(scratch, "cache"),
      source,
      join(app, "Tests/NotesPersistenceStateTests.swift"),
      "-o",
      executable,
    ],
    { stdio: "inherit" },
  );
  execFileSync(executable, [], { stdio: "inherit" });
} finally {
  rmSync(scratch, { recursive: true, force: true });
}
