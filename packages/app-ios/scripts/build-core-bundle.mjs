#!/usr/bin/env node
// SPDX-License-Identifier: GPL-3.0-or-later
// 把 packages/core 打成 JavaScriptCore 可加载的 IIFE bundle。
// 产物: CoreBridge/Generated/core.js（构建产物，不入库）
import { execFileSync } from "node:child_process";
import { mkdirSync, statSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(here, "../../..");
const entry = join(here, "core-entry.ts");
const outfile = join(here, "../CoreBridge/Generated/core.js");
const esbuild = join(repoRoot, "node_modules/.bin/esbuild");

mkdirSync(dirname(outfile), { recursive: true });

execFileSync(
  esbuild,
  [
    entry,
    "--bundle",
    "--format=iife",
    "--global-name=ReadAnyCore",
    "--platform=browser",
    "--target=es2020",
    // 打包产物直接进 App，压一下体积（加了 Mermaid 渲染后更值）
    "--minify",
    // app-expo 的元数据抽取里有 RN 专用的动态 import（我们只走纯字节路径），不打进包
    "--external:expo-file-system",
    "--external:expo-file-system/legacy",
    "--external:react-native",
    "--log-level=warning",
    `--outfile=${outfile}`,
  ],
  { stdio: "inherit", cwd: repoRoot },
);

const bytes = statSync(outfile).size;
const meta = {
  entry: "packages/app-ios/scripts/core-entry.ts",
  outfile: "packages/app-ios/CoreBridge/Generated/core.js",
  bytes,
  builtAt: new Date().toISOString(),
};
writeFileSync(join(here, "core-bundle-meta.json"), `${JSON.stringify(meta, null, 2)}\n`);

console.log(`core.js ${(bytes / 1024 / 1024).toFixed(2)} MB → ${outfile}`);
