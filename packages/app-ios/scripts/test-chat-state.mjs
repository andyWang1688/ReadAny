#!/usr/bin/env node
// SPDX-License-Identifier: GPL-3.0-or-later
// 用真实 ChatService 与可重放的宿主事件验证会话隔离，不需要模拟器或 API Key。
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const app = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const scratch = mkdtempSync(join(tmpdir(), "shudeng-chat-state-"));
try {
  const service = join(scratch, "ChatService.swift");
  writeFileSync(
    service,
    `import Combine\n${readFileSync(join(app, "Shudeng/Features/Chat/ChatService.swift"), "utf8")}`,
  );
  const executable = join(scratch, "chat-state-tests");
  execFileSync(
    "swiftc",
    [
      "-module-cache-path",
      join(scratch, "modulecache"),
      service,
      join(app, "Tests/ChatServiceStateTests.swift"),
      "-o",
      executable,
    ],
    { stdio: "inherit" },
  );
  execFileSync(executable, [], { stdio: "inherit" });
} finally {
  rmSync(scratch, { recursive: true, force: true });
}
