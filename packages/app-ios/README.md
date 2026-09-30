# 书灯 · Shudeng

> 一盏照书的灯，AI 照亮你读不懂的地方。

ReadAny 的 iOS 原生重写，只保留 iOS，UI 与交互全部重做。

## 架构

| 层 | 选型 | 说明 |
|---|---|---|
| UI | SwiftUI | 全量重写，Apple Music 风格，无 RN / Expo / Hermes |
| 逻辑 | `packages/core`（TypeScript） | 通过 JavaScriptCore 直接运行，复用 AI / RAG / 统计 / TTS / EPUB 解析 |
| 阅读渲染 | WKWebView + `packages/foliate-js` | EPUB 分页、高亮、笔记、TTS 跟读 |
| PDF | PDFKit | 替代 pdf.js，省约 1.6 MB |
| 向量 | Apple NLEmbedding | 替代 Transformers.js + onnxruntime |
| 宿主能力 | Swift | 网络（URLSession 流式 SSE）、SQLite、定时器、加密 |

装配顺序：`bridge-shim.js`（补 JSC 缺失 API）→ `core.js`（ReadAny core）→ `app-bootstrap.js`（把 Swift 原语包成 `IPlatformService`，注册 `ShudengApp` API）。

已打通的链路：

1. **导入**：`fileImporter`（EPUB / PDF）→ Swift 复制进 App 沙箱 `Documents/books/<id>.<ext>`（和旧版 ReadAny 同一目录，升级不丢书）→ `ShudengApp.importBook()` 用 core 抽元数据/封面（pako 解压 EPUB，纯 JS，不依赖 DOM）→ 写 `books` 表 → 书库网格显示。
2. **阅读**：书库点书 → `ReadingSession` → 阅读 Tab 的 WKWebView 加载 `reader.html`，Swift 注入 `window.ReactNativeWebView` 垫片接 `handleCommand({ type: 'openBook', base64, mimeType })`，foliate-js 分页渲染。
3. **AI 对话**：翻页 / 选中文字时 `reader.html` 回传 `relocate` / `selection` 事件，Swift 调 `window.getVisibleText()` 拿当前页正文存进 `ReadingSession`；提问时 `ChatService` 把「当前页（或选中段落）+ 历史 + 书元数据」交给 `ShudengApp.chat()`，core 的 LangChain 模型（含技能、思维导图、Mermaid、多 provider）在 JSC 里跑，token 经 `__nativeChatEvent` 流式回推 SwiftUI 气泡。
4. **数据**：SQLite 文件由 Swift 打开（`SQLiteDatabase`），core 的 `db` 模块经 `IPlatformService.loadDatabase()` 拿连接（优先旧版 `SQLite/<name>`，否则用 `Documents/<name>`）；键值走 `UserDefaults`，随机数走 Security 框架。
5. **AI 设置**：provider / Base URL / 模型名进 `UserDefaults`，API Key 只进 Keychain（`Keychain.swift`）；「我的 → AI 设置」和对话页右上角都能进。

## 目录

```
packages/app-ios/
├── Shudeng.xcodeproj/          # App 工程（手写 pbxproj，同步文件夹收源码与资源）
├── Shudeng/                    # SwiftUI App
│   ├── Core/RuntimeHost.swift      # 持有 JSContext，暴露 appJSON() 调 ShudengApp
│   ├── Core/ReadingSession.swift   # 当前打开的书（书库 → 阅读 Tab）
│   ├── Core/AISettings.swift       # AI 端点配置（Key 走 Keychain）
│   ├── Features/Library/           # LibraryStore 走 core db；LibraryView 是 Apple Music 风格网格 + 导入
│   ├── Features/Reader/            # WKWebView + foliate-js，书以 base64 注入
│   ├── Features/Chat/              # ChatService（流式状态机）+ ChatView（气泡 / 停止 / 清空）
│   ├── Features/Notes/             # 高亮 / 笔记 / 书签列表
│   ├── Features/Stats/             # 阅读统计（时长、连续天数、书目排行）
│   ├── Features/Settings/          # ProfileView（我的）+ AISettingsView + AboutView
│   └── Resources/                  # 构建产物 + LICENSE（core.js / reader.html 不入库）
├── CoreBridge/                 # SwiftPM 包：JavaScriptCore 宿主
│   ├── Sources/ShudengCoreBridge/
│   │   ├── ReadAnyRuntime.swift    # JSContext + shim + core 装配
│   │   ├── HostEnvironment.swift   # 定时器 / 文件系统 / KV / SQLite / 流式 fetch 注入
│   │   ├── StreamBridge.swift      # URLSession → JS 分片（SSE）
│   │   ├── SQLiteDatabase.swift    # IDatabase 宿主实现
│   │   └── Resources/              # bridge-shim.js（垫片）+ app-bootstrap.js（平台层）
│   └── Tests/ShudengCoreBridgeTests/
└── scripts/
    ├── core-entry.ts           # core 打包入口（ai/db/rag/stats/tts/epub）
    ├── build-core-bundle.mjs   # 产出 CoreBridge/Generated/core.js
    └── sync-app-assets.mjs     # core.js + reader.html → Shudeng/Resources/
```

## 命令

```bash
pnpm ios:core     # 打包 core → CoreBridge/Generated/core.js（4.57 MB）
pnpm ios:assets   # 复制 core.js + reader.html → Shudeng/Resources/（入 Xcode target）
pnpm ios:test     # 跑 CoreBridge 测试（core 加载 / LangChain / SQLite / 宿主平台层 / EPUB 导入 / 真实流式对话）
pnpm ios:ipa      # 出可直接装机的已签名 IPA（用本机 Apple Development 证书 + 开发描述文件）
```

`pnpm ios:test` 里的流式对话用例需要真端点，用环境变量给：

```bash
SHUDENG_TEST_BASE_URL=https://api.deepseek.com/v1 \
SHUDENG_TEST_API_KEY=sk-… \
SHUDENG_TEST_MODEL=deepseek-chat \
pnpm ios:test
```

`CoreBridge/Generated/` 是构建产物，不入库。

> 在 Codex 沙箱内跑测试需要 `CLANG_MODULE_CACHE_PATH=/private/tmp/shudeng-modulecache swift test --disable-sandbox --package-path packages/app-ios/CoreBridge`（嵌套 sandbox-exec 与默认 module cache 路径都会被拦），普通终端不需要。

## 构建 iOS App

Xcode 直接打开 `packages/app-ios/Shudeng.xcodeproj`（bundle id `com.wangxinxin.readany.personal`，team `9J638ZYKM2`，iOS 17+，仅 iPhone）——签名是 Automatic，插上 iPhone 直接 ⌘R 就能装。

```bash
pnpm ios:core && pnpm ios:assets
xcodebuild -project packages/app-ios/Shudeng.xcodeproj -scheme Shudeng \
  -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath /private/tmp/shudeng-dd CODE_SIGNING_ALLOWED=NO \
  OTHER_SWIFT_FLAGS="-disable-sandbox" build
```

`OTHER_SWIFT_FLAGS="-disable-sandbox"` 只在 Codex 沙箱内需要：SwiftUI 宏的 `swift-plugin-server` 在嵌套 sandbox 下起不来，普通终端去掉即可。

## 许可与分发

- 沿用仓库协议 **GPL-3.0-or-later**：复用了 `packages/core`，整个 App 按 GPL-3.0 分发，向拿到二进制的人提供对应源码。
- 新增源码文件（Swift / TS / JS）首行统一带 `SPDX-License-Identifier: GPL-3.0-or-later`；`Package.swift`（tools-version 必须首行）与 `bridge-shim.js` 放在第二行。
- App Bundle 内随包分发 `Shudeng/Resources/LICENSE`，与仓库根 `LICENSE` 字节一致（SHA-256 `8606c8a6…`），「我的 → 许可证」页读的就是它。
- 分发方式：公开源码仓库 + 自签 / 侧载（Xcode、AltStore），不走 App Store。
- 不上架的原因：Apple 的签名与 DRM 属于 GPLv3 禁止的额外限制。
- 以后若要上架，只需替换 `CoreBridge` 下面的 core（换成自写 Swift 实现），UI 与宿主层不受影响。

## 体积

- 实测 Release `.app` 7.4 MB（core.js 4.57 MB + reader.html 2.02 MB + bridge-shim/app-bootstrap 约 29 KB + 可执行文件）。
- core.js 从 4.21 MB 涨到 4.57 MB 是加了 EPUB 元数据抽取（pako 解压 ZIP）；后续若换 Swift 侧解析可再省下约 120 KB。
- Release 归档会去掉调试产物，剩下的主要是 core.js 与 reader.html；App Store 侧另有压缩，预算仍按约 8.4 MB 量级控制。
