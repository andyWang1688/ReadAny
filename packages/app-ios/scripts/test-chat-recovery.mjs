#!/usr/bin/env node
// SPDX-License-Identifier: GPL-3.0-or-later
// Real ChatService, JavaScriptCore and SQLite; only model token delivery is replayed.
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const app = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const bridge = join(app, "CoreBridge/Sources/ShudengCoreBridge");
const scratch = mkdtempSync(join(tmpdir(), "shudeng-chat-recovery-"));
try {
  const service = join(scratch, "ChatService.swift");
  writeFileSync(
    service,
    `import Combine\n${readFileSync(join(app, "Shudeng/Features/Chat/ChatService.swift"), "utf8")}`,
  );
  const executable = join(scratch, "test");
  execFileSync(
    "swiftc",
    [
      "-module-cache-path",
      join(scratch, "cache"),
      service,
      join(app, "Tests/ChatRecoveryTests.swift"),
      ...[
        "ReadAnyRuntime.swift",
        "HostEnvironment.swift",
        "SQLiteDatabase.swift",
        "StreamBridge.swift",
        "LocalEmbedding.swift",
      ].map((file) => join(bridge, file)),
      "-o",
      executable,
    ],
    { stdio: "inherit" },
  );
  execFileSync(executable, [app], { stdio: "inherit" });
} finally {
  rmSync(scratch, { recursive: true, force: true });
}
