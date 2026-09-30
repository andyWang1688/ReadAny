#!/usr/bin/env node
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 把模拟器屏幕做成 MJPEG 实时流：浏览器打开 http://127.0.0.1:8765 就能看着 UI 测试在点什么。
// （本机 Xcode 没带 Simulator.app，开不了模拟器窗口，用这个代替。）
//
//   node packages/app-ios/scripts/simulator-live.mjs [设备UDID] [端口]
import { createServer } from "node:http";
import { execFile } from "node:child_process";
import { readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const udid = process.argv[2] || "booted";
const port = Number(process.argv[3] || process.env.SIMSTREAM_PORT || 8765);
const framePath = join(tmpdir(), `shudeng-simframe-${process.pid}.jpg`);

const clients = new Set();
let capturing = false;
let frame = null;

function capture() {
  if (capturing || !clients.size) return;
  capturing = true;
  execFile("xcrun", ["simctl", "io", udid, "screenshot", "--type=jpeg", framePath], { timeout: 20000 }, (error) => {
    capturing = false;
    if (error) return;
    try {
      frame = readFileSync(framePath);
    } catch {}
  });
}

setInterval(capture, 250);

const page = `<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><title>书灯 · 模拟器实时画面</title>
<style>
  :root { color-scheme: dark; }
  body { margin:0; padding:24px; background:#0b0b0e; color:#e8e8ed; font:14px/1.5 -apple-system,"PingFang SC",sans-serif; display:flex; flex-direction:column; align-items:center; gap:14px; }
  h1 { font-size:16px; font-weight:600; margin:0; }
  .tag { color:#8b8b96; font-size:12.5px; }
  img { width:402px; max-width:90vw; border-radius:22px; border:1px solid #26262e; background:#000; }
  code { background:#1b1b22; padding:2px 6px; border-radius:6px; font-size:12px; }
</style></head>
<body>
  <h1>书灯 · iPhone 17 模拟器（实时）</h1>
  <div class="tag">测试脚本在点、在翻页、在朗读时，这里就是模拟器屏幕上发生的事（约 2 帧/秒）</div>
  <img src="/stream" alt="simulator">
  <div class="tag">设备 <code>${udid}</code> · 数据源 <code>xcrun simctl io … screenshot</code></div>
</body></html>`;

createServer((req, res) => {
  if (req.url === "/stream") {
    res.writeHead(200, {
      "Content-Type": "multipart/x-mixed-replace; boundary=frame",
      "Cache-Control": "no-store",
    });
    clients.add(res);
    const timer = setInterval(() => {
      if (!frame) return;
      res.write(`--frame\r\nContent-Type: image/jpeg\r\nContent-Length: ${frame.length}\r\n\r\n`);
      res.write(frame);
      res.write("\r\n");
    }, 220);
    req.on("close", () => {
      clearInterval(timer);
      clients.delete(res);
    });
    return;
  }
  res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
  res.end(page);
}).listen(port, "127.0.0.1", () => {
  console.log(`模拟器实时画面: http://127.0.0.1:${port}  （设备 ${udid}）`);
});

function shutdown() {
  try { rmSync(framePath, { force: true }); } catch {}
  process.exit(0);
}
process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
