// SPDX-License-Identifier: GPL-3.0-or-later
// EPUB 正文抽取：给「建立语义索引」用。
// 阅读器里的 epub.js 要开界面才能取正文；建索引是在书库里点一下就跑的，
// 所以这里用 pako 直接解 zip（只解 spine 里的 xhtml，不碰图片）。
import pako from "pako";

export interface EpubChapterText {
  index: number;
  title: string;
  content: string;
  /**
   * 切块用的段落。core 的 chunker 只吃 segments（它按段落的 cfi 记位置），
   * 这里没开阅读器拿不到 foliate 的 cfi，所以 cfi 留空：检索结果回跳用的是
   * 正文片段让阅读器自己搜，不靠 cfi。
   */
  segments: { text: string; cfi: string }[];
}

interface ZipEntry {
  filename: string;
  compressionMethod: number;
  compressedSize: number;
  localHeaderOffset: number;
}

/** 读 zip 中央目录（EPUB 就是 zip，写法跟 app-expo 的元数据抽取保持一致）。 */
function readZipDirectory(buf: Uint8Array): ZipEntry[] {
  const view = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
  let eocd = -1;
  for (let i = buf.byteLength - 22; i >= 0 && i >= buf.byteLength - 65557; i--) {
    if (view.getUint32(i, true) === 0x06054b50) {
      eocd = i;
      break;
    }
  }
  if (eocd === -1) return [];

  const count = view.getUint16(eocd + 10, true);
  const cdOffset = view.getUint32(eocd + 16, true);
  const cdSize = view.getUint32(eocd + 12, true);
  if (cdOffset < 0 || cdOffset + cdSize > buf.byteLength) return [];

  const entries: ZipEntry[] = [];
  let pos = cdOffset;
  for (let i = 0; i < count && pos + 46 <= buf.byteLength; i++) {
    if (view.getUint32(pos, true) !== 0x02014b50) break;
    const filenameLen = view.getUint16(pos + 28, true);
    const extraLen = view.getUint16(pos + 30, true);
    const commentLen = view.getUint16(pos + 32, true);
    entries.push({
      filename: new TextDecoder().decode(buf.slice(pos + 46, pos + 46 + filenameLen)),
      compressionMethod: view.getUint16(pos + 10, true),
      compressedSize: view.getUint32(pos + 20, true),
      localHeaderOffset: view.getUint32(pos + 42, true),
    });
    pos += 46 + filenameLen + extraLen + commentLen;
  }
  return entries;
}

function inflateEntry(buf: Uint8Array, entry: ZipEntry): Uint8Array | null {
  const view = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
  if (entry.localHeaderOffset + 30 > buf.byteLength) return null;
  const nameLen = view.getUint16(entry.localHeaderOffset + 26, true);
  const extraLen = view.getUint16(entry.localHeaderOffset + 28, true);
  const start = entry.localHeaderOffset + 30 + nameLen + extraLen;
  if (start + entry.compressedSize > buf.byteLength) return null;
  const data = buf.slice(start, start + entry.compressedSize);
  if (entry.compressionMethod === 0) return data;
  if (entry.compressionMethod === 8) {
    try {
      return pako.inflateRaw(data);
    } catch {
      return null;
    }
  }
  return null;
}

function decode(bytes: Uint8Array | null): string {
  return bytes ? new TextDecoder().decode(bytes) : "";
}

/** `OEBPS/text/ch1.xhtml` + `../images/a.png` → `OEBPS/images/a.png` */
function resolvePath(base: string, relative: string): string {
  const parts = `${base}/${relative}`.split("/");
  const stack: string[] = [];
  for (const part of parts) {
    if (!part || part === ".") continue;
    if (part === "..") stack.pop();
    else stack.push(part);
  }
  return stack.join("/");
}

function directoryOf(path: string): string {
  const index = path.lastIndexOf("/");
  return index === -1 ? "" : path.slice(0, index);
}

function attribute(tag: string, name: string): string {
  const match = new RegExp(`${name}\\s*=\\s*"([^"]*)"`, "i").exec(tag);
  return match ? match[1] : "";
}

function unescapeEntities(text: string): string {
  return text
    .replace(/&nbsp;/gi, " ")
    .replace(/&amp;/gi, "&")
    .replace(/&lt;/gi, "<")
    .replace(/&gt;/gi, ">")
    .replace(/&quot;/gi, '"')
    .replace(/&#39;|&apos;/gi, "'")
    .replace(/&#x([0-9a-f]+);/gi, (_, hex) => String.fromCodePoint(Number.parseInt(hex, 16)))
    .replace(/&#(\d+);/g, (_, dec) => String.fromCodePoint(Number.parseInt(dec, 10)));
}

/** XHTML → 段落数组：块级标签切段，其余当分隔，标签全去掉。 */
function htmlToParagraphs(html: string): string[] {
  return unescapeEntities(
    html
      .replace(/<!--[\s\S]*?-->/g, "")
      .replace(/<(script|style|head)[\s\S]*?<\/\1>/gi, "")
      .replace(/<br\s*\/?>/gi, "\n")
      .replace(/<\/(p|div|section|article|li|h[1-6]|tr|blockquote)>/gi, "\n")
      .replace(/<[^>]+>/g, ""),
  )
    .split("\n")
    .map((line) => line.replace(/\s+/g, " ").trim())
    .filter((line) => line.length > 0);
}

function htmlToText(html: string): string {
  return htmlToParagraphs(html).join("\n");
}

function titleOf(html: string, fallback: string): string {
  const head = /<title[^>]*>([\s\S]*?)<\/title>/i.exec(html);
  const heading = /<h[1-3][^>]*>([\s\S]*?)<\/h[1-3]>/i.exec(html);
  const raw = (head?.[1] || heading?.[1] || "").trim();
  const text = htmlToText(raw).split("\n")[0] || "";
  return text.slice(0, 80) || fallback;
}

/** 按 spine 顺序抽出全部章节正文（跳过空章节）。 */
export function extractEpubChapters(bytes: Uint8Array): EpubChapterText[] {
  const entries = readZipDirectory(bytes);
  if (!entries.length) throw new Error("不是有效的 EPUB（zip 目录读不出来）");

  const byName = new Map(entries.map((entry) => [entry.filename, entry]));
  const readText = (name: string): string => {
    const entry = byName.get(name);
    return entry ? decode(inflateEntry(bytes, entry)) : "";
  };

  const container = readText("META-INF/container.xml");
  // 注意 `<rootfile` 会命中 `<rootfiles>`，必须带单词边界
  const opfPath = attribute(/<rootfile\b[^>]*>/i.exec(container)?.[0] || "", "full-path");
  if (!opfPath) throw new Error("EPUB 里找不到 OPF");
  const opf = readText(opfPath);
  const opfDir = directoryOf(opfPath);

  const manifest = new Map<string, { href: string; type: string }>();
  for (const tag of opf.match(/<item\b[^>]*>/gi) || []) {
    manifest.set(attribute(tag, "id"), {
      href: attribute(tag, "href"),
      type: attribute(tag, "media-type"),
    });
  }

  const chapters: EpubChapterText[] = [];
  for (const tag of opf.match(/<itemref\b[^>]*>/gi) || []) {
    const item = manifest.get(attribute(tag, "idref"));
    if (!item?.href) continue;
    if (item.type && !/xhtml|html/.test(item.type)) continue;
    const html = readText(resolvePath(opfDir, item.href));
    const paragraphs = htmlToParagraphs(html);
    const content = paragraphs.join("\n\n");
    if (content.replace(/\s/g, "").length < 40) continue;
    chapters.push({
      index: chapters.length,
      title: titleOf(html, `第 ${chapters.length + 1} 章`),
      content,
      segments: paragraphs.map((text) => ({ text, cfi: "" })),
    });
  }
  if (!chapters.length) throw new Error("EPUB 里没有可索引的章节正文");
  return chapters;
}
