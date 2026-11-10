import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
const source = fs.readFileSync(new URL('../../lib/epub_reader.dart', import.meta.url), 'utf8');
const anchorCode = source.slice(source.indexOf('    var anchor = tgt'), source.indexOf('    // Ignore if the user selected text'));
const scrollCode = source.slice(source.indexOf('  window.__cupEpubScrollToReference ='), source.indexOf('  window.__cupEpubRestoreScroll ='));
const messages = [];
const context = vm.createContext({ window: {}, document: {}, Date, decodeURIComponent, post: m => messages.push(m) });
vm.runInContext('function clickLink(tgt, ev) {\n' + anchorCode.replaceAll('\\\\', '\\') + '\n}', context);
for (const href of ['#ref-note-8', 'chapter-07.xhtml#ref-note-8', '../notes.xhtml#back', 'cupitor-epub://chapter/chapter-07.xhtml#ref-note-8']) {
  let prevented = false;
  context.clickLink({closest: () => ({getAttribute: () => href})}, {preventDefault() { prevented = true; }});
  assert.equal(prevented, true, 'internal links must not navigate the WebView');
  assert.equal(messages.at(-1).href, href);
}
let prevented = false;
context.clickLink({closest: () => ({getAttribute: () => 'https://example.com'})}, {preventDefault() { prevented = true; }});
assert.equal(prevented, false, 'external link handling stays native');
let scrolled = false;
context.document.getElementById = id => id === 'rätt' ? {scrollIntoView() {scrolled = true;}} : null;
context.document.getElementsByName = () => [];
vm.runInContext(scrollCode, context);
context.window.__cupEpubScrollToReference('r%C3%A4tt');
assert.equal(scrolled, true, 'encoded reference ids resolve to DOM anchors');
console.log('EPUB internal reference interception and anchor scrolling passed');
