#!/usr/bin/env node
// SPDX-License-Identifier: GPL-3.0-or-later
// 用真实 ReadingSession 与可重放的宿主事件验证阅读记录重试，不需要模拟器或 API Key。
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const app = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const scratch = mkdtempSync(join(tmpdir(), "shudeng-reading-session-state-"));
try {
  const service = join(scratch, "ReadingSession.swift");
  writeFileSync(
    service,
    `import Combine\n${readFileSync(join(app, "Shudeng/Core/ReadingSession.swift"), "utf8")}`,
  );
  const executable = join(scratch, "reading-session-state-tests");
  execFileSync(
    "swiftc",
    [
      "-module-cache-path",
      join(scratch, "modulecache"),
      service,
      join(app, "Tests/ReadingSessionStateTests.swift"),
      "-o",
      executable,
    ],
    { stdio: "inherit" },
  );
  execFileSync(executable, [], { stdio: "inherit" });
} finally {
  rmSync(scratch, { recursive: true, force: true });
}
