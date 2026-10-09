#!/usr/bin/env node
// SPDX-License-Identifier: GPL-3.0-or-later
// Actual rename persistence and editor save action, with a failing host boundary.
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
const app = process.env.READANY_TEST_APP || resolve(dirname(fileURLToPath(import.meta.url)), "..");
const view = readFileSync(join(app, "Shudeng/Features/Chat/ChatListView.swift"), "utf8");
let save;
if (view.includes("    private func saveRename()")) {
  const start = view.indexOf("    private func saveRename()");
  save = view.slice(start, view.indexOf("\n    }", start) + 6).replace("private func", "func");
} else {
  const start = view.indexOf("                    if let thread = renaming {");
  save = `func saveRename() {\n${view.slice(start, view.indexOf("                }\n            }\n            .sheet", start))}\n}`;
}
let fixture = readFileSync(join(app, "Tests/ChatServiceStateTests.swift"), "utf8").split(
  "@main struct",
)[0];
fixture = fixture.replace(
  '    var failPrefix = ""',
  '    var failPrefix = ""\n    var renameReceipt: String?',
);
fixture = fixture.replace(
  '        if expression.hasPrefix("ShudengApp.renameThread") {',
  '        if expression.hasPrefix("ShudengApp.renameThread") {\n            if let renameReceipt { return renameReceipt }',
);
const scratch = mkdtempSync(join(tmpdir(), "shudeng-chat-rename-"));
try {
  const source = join(scratch, "Source.swift");
  const test = join(scratch, "Tests.swift");
  const executable = join(scratch, "test");
  writeFileSync(
    source,
    `import Combine\n${readFileSync(join(app, "Shudeng/Features/Chat/ChatService.swift"), "utf8")}\n${fixture}\n@MainActor final class RenameProbe {\nlet chat = ChatService(), runtime = RuntimeHost()\nvar renaming: ChatThread?, renameText = ""\n${save}\n}`,
  );
  writeFileSync(
    test,
    readFileSync(
      process.env.READANY_TEST_FIXTURE || join(app, "Tests/ChatRenameStateTests.swift"),
      "utf8",
    ),
  );
  execFileSync(
    "swiftc",
    ["-module-cache-path", join(scratch, "cache"), source, test, "-o", executable],
    { stdio: "inherit" },
  );
  execFileSync(executable, [], { stdio: "inherit" });
} finally {
  rmSync(scratch, { recursive: true, force: true });
}
