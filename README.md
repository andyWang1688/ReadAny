<h1 align="center">Shudeng · 书灯</h1>

<p align="center">
  <strong>A local-first AI reading app for iPhone</strong><br>
  A lamp for your books — it lights up the parts you cannot understand on your own.
</p>

<p align="center">
  <img alt="Platform" src="https://img.shields.io/badge/iOS-17%2B-blue">
  <img alt="SwiftUI" src="https://img.shields.io/badge/UI-SwiftUI-black">
  <img alt="License" src="https://img.shields.io/badge/license-GPL--3.0--or--later-green">
  <a href="README_CN.md"><img alt="中文" src="https://img.shields.io/badge/lang-中文-red"></a>
</p>

---

Shudeng puts reading and asking on the same screen. Open an EPUB or PDF, select a passage you do not understand, and ask the AI right there — the answer is grounded in the page you are on. Books, highlights, notes, and conversations all stay on your device.

> Built on top of [ReadAny](https://github.com/codedogQBY/ReadAny) (GPL-3.0-or-later). The desktop and web apps in this repository come from upstream; Shudeng is a native iOS rewrite of the same core, living in `packages/app-ios/`.

## Screenshots

| Library | Reader |
| --- | --- |
| ![Library](assets/ios/library.png) | ![Reader](assets/ios/reader.png) |

| AI chat | Notes | Reading stats |
| --- | --- | --- |
| ![AI chat](assets/ios/ai-threads.png) | ![Notes](assets/ios/notes.png) | ![Reading stats](assets/ios/stats.png) |

## What it solves

| The annoying part of reading | Ordinary readers | Shudeng |
| --- | --- | --- |
| You forget what you read and cannot find the passage again | Keyword search only | Semantic search finds the passage by meaning |
| You hit something you do not understand | Leave the book, look it up, lose your place | Select the text and ask in place, with the current page as context |
| Notes end up scattered | Written in another app | Highlights, notes, and bookmarks collected per book, exportable |
| Privacy | Content and notes in the cloud | Books and notes never leave the device; bring your own model |

## Features

**Library** — Import EPUB / PDF from Files or AirDrop, cover grid, search by title or author, semantic search across indexed books, filters (all / reading / unread / finished), sorting, and per-book progress.

**Reader** — Paged or continuous scrolling; table of contents, in-book search, bookmarks; white / black / sepia themes; adjustable font size, line height, and margins; a footer that shows chapter progress, book percentage, and time left; the top bar can be hidden for a clean page.

**AI chat** — History grouped by book, with a separate bucket for chats that are not tied to any book; start a new chat and pick a book with a chip, or just ask freely. Ask about selected text or the current page, watch answers stream in, and expand the thinking process when you want it. Skills cover mind maps and Mermaid diagrams. Providers: OpenAI-compatible, Anthropic, Gemini, or your own endpoint. API keys live in the Keychain.

**Notes** — Highlights, notes, and bookmarks in one place, grouped by book, searchable, and exportable.

**Reading stats** — Today / this week / all-time reading time, streaks, a 14-day chart; reports by week, month, or all time with an optional AI summary; badges and a per-book ranking.

**Text to speech** — Reads the text aloud with the system voice, highlights along, and supports a sleep timer.

**Profile** — Appearance (theme and accent color), AI settings, semantic search (vector model), and about / license.

## Install

Shudeng is not on the App Store — install it by building it yourself or sideloading a signed build (Apple's signing and DRM are incompatible with GPLv3, see [License](#license)).

```bash
git clone https://github.com/andyWang1688/ReadAny.git
cd ReadAny
pnpm install
pnpm ios:core && pnpm ios:assets   # bundle core and reader assets, build products are not committed
```

The fastest route to an installable build:

```bash
pnpm ios:ipa   # signed IPA using your local Apple Development certificate and provisioning profile
```

Or just use Xcode: open `packages/app-ios/Shudeng.xcodeproj`, set Signing to your own team, plug in an iPhone, and press ⌘R. Requires iOS 17+, iPhone only.

## Development

### Architecture

| Layer | Choice | Notes |
| --- | --- | --- |
| UI | SwiftUI | Native, no React Native / Expo |
| Logic | `packages/core` (TypeScript) | Runs inside JavaScriptCore; reuses AI, RAG, stats, TTS, EPUB parsing |
| Reading view | WKWebView + `packages/foliate-js` | Pagination, highlights, notes, follow-along reading |
| PDF | PDFKit | Replaces pdf.js |
| Vectors | Apple NLEmbedding | Embeddings computed on device |
| Host | Swift | Streaming network (URLSession SSE), SQLite, timers, Keychain |

Boot order: `bridge-shim.js` (fills the gaps in JSC) → `core.js` → `app-bootstrap.js` (wraps Swift primitives into `IPlatformService`). More detail in [`packages/app-ios/README.md`](packages/app-ios/README.md) (Chinese).

### Commands

```bash
pnpm ios:core     # bundle core → CoreBridge/Generated/core.js
pnpm ios:assets   # core.js + reader.html → Shudeng/Resources/
pnpm ios:test     # CoreBridge tests (core loading, LangChain, SQLite, host layer, EPUB import, streaming chat)
pnpm ios:ipa      # build a signed IPA

# Run XCUITest on a simulator or device (simulators get a mock AI endpoint automatically)
bash packages/app-ios/scripts/run-ui-tests.sh <device UDID>
```

## Testing

- **CoreBridge (SwiftPM)**: `pnpm ios:test`. The live streaming test needs an endpoint — pass `SHUDENG_TEST_BASE_URL`, `SHUDENG_TEST_API_KEY`, and `SHUDENG_TEST_MODEL`.
- **XCUITest**: 23 cases covering library, reader, AI chat, notes, stats, settings, import, and restore-after-reinstall; run them all through `run-ui-tests.sh`.

## Data and privacy

Books, covers, progress, highlights, notes, and chat history are stored on device (SQLite and app sandbox files). Only when you ask a question does the app send the current page or selected text plus the conversation history to the model endpoint you configured yourself — both the URL and the key are yours, and the key is kept in the Keychain. There is no account system and no telemetry.

## License

- **GPL-3.0-or-later** (see [LICENSE](LICENSE)). Shudeng reuses ReadAny's `packages/core`, so the whole app is distributed under GPL-3.0 with corresponding source available.
- Because GPLv3 does not accept Apple's additional signing and DRM restrictions, Shudeng is distributed as source plus self-signed / sideloaded builds rather than through the App Store.
- Thanks to [ReadAny](https://github.com/codedogQBY/ReadAny) (core, semantic search, skills) and [foliate-js](https://github.com/johnfactotum/foliate-js) (EPUB rendering).
