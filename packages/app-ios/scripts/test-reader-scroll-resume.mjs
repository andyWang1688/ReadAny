#!/usr/bin/env node
// SPDX-License-Identifier: GPL-3.0-or-later
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";

for (const file of ["reader.template.html", "reader.html"]) {
  const html = readFileSync(new URL(`../../app-expo/assets/reader/${file}`, import.meta.url), "utf8");
  const start = html.indexOf("    function scrollLayoutKey()");
  const end = html.indexOf("    // ─── Search ───", start);
  assert.ok(start >= 0 && end > start);
  const renderer = { scrolled: true, getAttribute: () => "20px" };
  const context = vm.createContext({
    view: { renderer }, window: { innerWidth: 393, innerHeight: 778 },
    currentBook: { sections: [{}, {}, {}] }, currentFontSize: 16,
    currentLineHeight: 1.6, currentParagraphSpacing: 8, currentFontTheme: "system",
    currentUseBookFonts: true, currentJustifyBodyText: true,
    currentCustomFontFamily: "", currentCustomFontFaceCSS: "",
  });
  vm.runInContext(html.slice(start, end), context);
  const saved = JSON.stringify({ cfi: "position-A", layout: context.scrollLayoutKey(), position: { index: 1, offset: -46.5 } });
  const match = () => context.matchingScrollResume(saved, "position-A", renderer);
  assert.equal(match().offset, -46.5, "chapter-boundary whitespace must survive");
  assert.equal(context.matchingScrollResume(saved, "position-B", renderer), null, "a stale refinement cannot override a bookmark or newer CFI");
  context.currentFontSize = 32;
  assert.equal(match(), null, "changed typography must fall back to CFI");
  context.currentFontSize = 16;
  context.window.innerWidth = 852;
  assert.equal(match(), null, "rotation must fall back to CFI");
  context.window.innerWidth = 393;
  renderer.scrolled = false;
  assert.equal(match(), null, "pagination cannot consume scroll offsets");
  renderer.scrolled = true;
  for (const raw of ["broken", "null", JSON.stringify({ cfi: "position-A", layout: context.scrollLayoutKey(), position: { index: 8, offset: 1 } })]) {
    assert.equal(context.matchingScrollResume(raw, "position-A", renderer), null, "unusable optional state must not prevent opening the book");
  }
}
console.log("Scroll resume guards passed for template and bundle");
