// SPDX-License-Identifier: GPL-3.0-or-later
// 书灯 iOS 端的 core 入口：只暴露 App 真正要用的模块。
// 构建产物是 IIFE，全局名 ReadAnyCore，由 JavaScriptCore 加载。
export * as ai from "../../core/src/ai/index.ts";
export * as services from "../../core/src/services/index.ts";
export * as db from "../../core/src/db/index.ts";
export * as rag from "../../core/src/rag/index.ts";
// AI 技能（core 的 builtin skills 定义 + 执行器）
export * as skills from "../../core/src/ai/skills/index.ts";
export * as stats from "../../core/src/stats/index.ts";
export * as tts from "../../core/src/tts/index.ts";
export * as utils from "../../core/src/utils/index.ts";
export * as epub from "../../core/src/epub/chapter.ts";
// EPUB 正文抽取（建语义索引要整本书的章节文本，阅读器没开也得能抽）
export * as epubText from "./epub-chapters.ts";
export * as messages from "@langchain/core/messages";
// EPUB 元数据/封面抽取复用 app-expo 的实现（只依赖 pako，能在 JSC 里跑）
export * as bookImport from "../../app-expo/src/lib/book/metadata-extractor.ts";
// 导入去重（书灯按文件内容哈希跳过重复导入）与选中翻译（复用同一个 AI 端点）
export * as importDedupe from "../../core/src/import/import-dedupe.ts";
export * as translation from "../../core/src/translation/providers.ts";
// Mermaid 图表渲染（零 DOM 依赖的纯 JS，直接吐 SVG 字符串，给对话里的 ```mermaid 用）
export * as diagram from "beautiful-mermaid";
// 徽章文案（title / desc / 分类名）在 core 的 stats 语言包里，这里只挑出这两份表格，
// 免得为了 39 个徽章名把整套 react-i18next 打进 JSC bundle。
import enStats from "../../core/src/i18n/locales/en/stats.json";
import zhStats from "../../core/src/i18n/locales/zh/stats.json";

const desktopText = (table: { stats: { desktop: Record<string, string> } }) => table.stats.desktop;

export const badgeText = {
  en: desktopText(enStats),
  zh: desktopText(zhStats),
};
