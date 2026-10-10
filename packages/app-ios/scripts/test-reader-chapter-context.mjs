#!/usr/bin/env node
// SPDX-License-Identifier: GPL-3.0-or-later
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

function chapter(text) {
  return { body: { innerText: text }, querySelectorAll: () => [
    { innerText: text, tagName: 'P', setAttribute() {} },
  ] };
}
const old = chapter('Previous chapter');
const visible = chapter('Visible chapter');
let checks = 0;
for (const file of ['reader.template.html', 'reader.html']) {
  const html = readFileSync(new URL(`../../app-expo/assets/reader/${file}`, import.meta.url), 'utf8');
  const start = html.indexOf('    async function handleGetChapterParagraphs()');
  const end = html.indexOf('    function getReaderLayoutSignature', start);
  assert.ok(start >= 0 && end > start);
  async function run(getContents, onWait = () => {}, legacy = []) {
    const events = [];
    const context = vm.createContext({
      view: { renderer: { primaryIndex: 1, ...(getContents ? { getContents } : {}) } },
      currentSectionIndex: 2,
      document: { querySelectorAll: () => legacy.map(contentDocument => ({ contentDocument })) },
      setTimeout: fn => { onWait(context); fn(); },
      postToRN: (type, payload) => events.push(JSON.parse(JSON.stringify({ type, ...payload }))),
    });
    vm.runInContext(html.slice(start, end), context);
    await context.handleGetChapterParagraphs();
    return events;
  }
  let events = await run(() => [{ index: 1, doc: old }, { index: 2, doc: visible }]);
  assert.equal(events[0].section, 2, file);
  assert.equal(events[0].paragraphs[0].text, 'Visible chapter', `${file}: primary pixel section must not override visible text section`);
  checks++;

  let loaded = false;
  events = await run(() => [{ index: 1, doc: old }, ...(loaded ? [{ index: 2, doc: visible }] : [])], () => { loaded = true; }, [old]);
  assert.equal(events[0].paragraphs[0].text, 'Visible chapter', `${file}: wait for target instead of using an adjacent or outer iframe`);
  checks++;

  events = await run(() => [{ index: 1, doc: old }]);
  assert.deepEqual(events[0].paragraphs, [], `${file}: missing target must not produce another chapter`);
  assert.equal(events[0].section, 2);
  assert.ok(events[0].error);
  checks++;

  loaded = false;
  events = await run(() => loaded ? [{ index: 2, doc: visible }, { index: 3, doc: old }] : [], context => {
    loaded = true;
    context.currentSectionIndex = 3;
  });
  assert.equal(events[0].section, 2, `${file}: an in-flight request must preserve its chapter identity`);
  assert.equal(events[0].paragraphs[0].text, 'Visible chapter');
  checks++;

  events = await run(null, undefined, [visible]);
  assert.equal(events[0].paragraphs[0].text, 'Visible chapter', `${file}: legacy iframe renderer remains supported`);
  checks++;
}
console.log(`Reader chapter context: ${checks} scenarios passed for template and bundle`);

// The fixed-layout renderer must expose the same section identity as Paginator.
{
  const source = readFileSync(new URL('../../foliate-js/fixed-layout.js', import.meta.url), 'utf8');
  const frameStart = source.indexOf('  async #createFrame(');
  const frameEnd = source.indexOf('  #render(', frameStart);
  const contentStart = source.indexOf('  getContents()');
  const contentEnd = source.indexOf('  destroy()', contentStart);
  assert.ok(frameStart >= 0 && frameEnd > frameStart && contentStart >= 0 && contentEnd > contentStart);
  const frames = [];
  const root = { append() {}, querySelectorAll: () => frames };
  const context = vm.createContext({
    root, defaultViewport: undefined, dispatchEvent() {},
    CustomEvent: function (type, options) { return { type, ...options }; },
    getViewport: () => ({ width: 400, height: 800 }),
    document: { createElement(tag) {
      const element = { dataset: {}, style: {}, append() {}, setAttribute() {} };
      if (tag === 'iframe') {
        element.contentDocument = chapter('Fixed page');
        element.addEventListener = (_, listener) => { element.onLoad = listener; };
        Object.defineProperty(element, 'src', { set() { element.onLoad(); } });
        frames.push(element);
      }
      return element;
    } },
  });
  vm.runInContext(source.slice(frameStart, frameEnd).replace('async #createFrame', 'async function createFrame').replaceAll('this.#root', 'root'), context);
  vm.runInContext(source.slice(contentStart, contentEnd).replace('getContents()', 'function getContents()').replaceAll('this.#root', 'root'), context);
  await context.createFrame({ index: 4, src: 'fixture.xhtml' });
  await context.createFrame({ index: 5, src: 'fixture-next.xhtml' });
  const contents = context.getContents();
  assert.equal(contents[0].index, 4, 'fixed-layout left/center document identity');
  assert.equal(contents[1].index, 5, 'fixed-layout right document identity');
  assert.equal(contents[0].doc, frames[0].contentDocument);
  console.log('Fixed-layout chapter identity passed');
}
