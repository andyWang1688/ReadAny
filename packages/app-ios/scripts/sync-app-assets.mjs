#!/usr/bin/env node
// SPDX-License-Identifier: GPL-3.0-or-later
// 把 App Bundle 需要的资源复制进 Shudeng/Resources（该目录由 Xcode 同步文件夹自动收进 target）。
import { copyFileSync, existsSync, mkdirSync, statSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const appDir = resolve(here, "..");
const repo = resolve(appDir, "../..");

const resources = join(appDir, "Shudeng", "Resources");
mkdirSync(resources, { recursive: true });

const assets = [
  {
    name: "core.js",
    from: join(appDir, "CoreBridge", "Generated", "core.js"),
    hint: "先跑 pnpm ios:core",
  },
  {
    name: "reader.html",
    from: join(repo, "packages", "app-expo", "assets", "reader", "reader.html"),
    hint: "先跑 pnpm --filter @readany/app-expo build:reader",
  },
];

for (const asset of assets) {
  if (!existsSync(asset.from)) {
    console.error(`missing ${asset.from}（${asset.hint}）`);
    process.exit(1);
  }
  const to = join(resources, asset.name);
  copyFileSync(asset.from, to);
  console.log(`${asset.name} ${(statSync(to).size / 1024 / 1024).toFixed(2)} MB → ${to}`);
}
