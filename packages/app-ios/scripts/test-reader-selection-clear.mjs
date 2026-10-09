#!/usr/bin/env node
// SPDX-License-Identifier: GPL-3.0-or-later
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";

const html = readFileSync(
  new URL("../../app-expo/assets/reader/reader.html", import.meta.url),
  "utf8",
);
const start = html.indexOf("    function clearDocumentSelection()");
const end = html.indexOf("    function getRangeTextWithoutRuby", start);
assert.ok(start >= 0 && end > start);
const source = html.slice(start, end);

function chapter() {
  const selection = {
    isCollapsed: false,
    clears: 0,
    removeAllRanges() {
      this.isCollapsed = true;
      this.clears++;
    },
  };
  return { selection, getSelection: () => selection };
}

const outer = chapter();
const visible = chapter();
const preloaded = chapter();
const legacy = chapter();
// The outer query cannot see Foliate's closed shadow root.
outer.querySelectorAll = () => [{ contentDocument: legacy }];
vm.runInNewContext(`${source}\nclearDocumentSelection();`, {
  document: outer,
  getRendererContents: () => [{ doc: visible }, { doc: preloaded }, { doc: visible }],
});
for (const doc of [outer, visible, preloaded, legacy]) {
  assert.equal(doc.selection.isCollapsed, true);
  assert.equal(doc.selection.clears, 1);
}
console.log("Reader selection clearing passed (outer, active, preloaded, legacy documents)");
