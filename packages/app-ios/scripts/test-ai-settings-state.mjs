#!/usr/bin/env node
// SPDX-License-Identifier: GPL-3.0-or-later
// 运行实际设置与密钥实现，仅替换 Security/Defaults 边界，绝不访问真实凭据。
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
const app = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const scratch = mkdtempSync(join(tmpdir(), "shudeng-ai-settings-"));
try {
  const keychain = readFileSync(join(app, "Shudeng/Core/Keychain.swift"), "utf8")
    .replaceAll("SecItemDelete(", "fixtureDelete(")
    .replaceAll("SecItemUpdate(", "fixtureUpdate(")
    .replaceAll("SecItemAdd(", "fixtureAdd(")
    .replaceAll("SecItemCopyMatching(", "fixtureCopy(");
  const settings = readFileSync(join(app, "Shudeng/Core/AISettings.swift"), "utf8")
    .replaceAll("UserDefaults.standard", "FixtureDefaults.standard");
  const source = join(scratch, "Sources.swift");
  writeFileSync(source, "import Combine\n" + keychain + "\n" + settings);
  const executable = join(scratch, "ai-settings-tests");
  execFileSync("swiftc", ["-module-cache-path", join(scratch, "modulecache"), source,
    join(app, "Tests/AISettingsStateTests.swift"), "-o", executable], { stdio: "inherit" });
  execFileSync(executable, [], { stdio: "inherit" });
} finally { rmSync(scratch, { recursive: true, force: true }); }
