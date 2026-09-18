#!/usr/bin/env node
// Behavioural tests for assets/js/page_export.js — the "Save page HTML…"
// export. The contract: the returned document is the page as rendered; with
// `strip` every trace of Cupitor's own additions is gone and the site's own
// markup is intact; either way a <base> makes relative URLs resolve; and the
// live document is never modified.
//
// Runs on Node with jsdom, taken from the webapp checkout beside this repo or
// from $CUPITOR_JSDOM.
//
//   node tools/page_export_test.js
'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');

function loadJsdom() {
  const candidates = [
    process.env.CUPITOR_JSDOM,
    'jsdom',
    path.resolve(ROOT, '../../cupitor/frontend/vue3/cupitor-frontend/node_modules/jsdom'),
  ].filter(Boolean);
  for (const c of candidates) {
    try { return require(c); } catch (_) { /* try the next */ }
  }
  console.error('jsdom not found. Point CUPITOR_JSDOM at a jsdom package directory.');
  process.exit(2);
}
const { JSDOM } = loadJsdom();

const PAGE_EXPORT_JS = fs.readFileSync(path.join(ROOT, 'assets/js/page_export.js'), 'utf8');

function page(html, url = 'https://example.test/book/ch1?x=1') {
  const dom = new JSDOM(html, { runScripts: 'outside-only', url });
  dom.window.eval(PAGE_EXPORT_JS);
  return dom;
}

// A page after Cupitor has been at it: wrapped words, a transformed word, a
// mask, tag marks on a span, the tagging stylesheet, a Dart-injected style,
// the Wiktionary banner, a YouTube bar, the filter class on <body>, a
// find-in-page highlight, page zoom on <html>, and the remote snippet's
// stylesheet, sidebar, picker panel and marks on the site's own player.
const INJECTED_PAGE = `<!DOCTYPE html><html class="no-js cupitor-filter-active" data-cupitor-lang="sv" style="zoom: 1.15; background: url('a;zoom:b.png'); -moz-box-orient: vertical; color: red"><head><meta charset="iso-8859-1"><title>Kalinka</title>
<style id="__cupitor_st_styles">.x{}</style>
<style data-cupitor-injected>body{filter:none}</style>
<style id="cup-sub-css">.cup-sub-cue{}</style>
<style>.cup-pc { position: fixed; }</style>
<style>.cup-pcs { margin: 0 } /* .cup-pc named in a comment */ .hero { color: red }</style>
<script>window.site = 1;</script></head>
<body class="theme cupitor-filter-active cup-sub-split" style="--cup-vid-h: 40vh">
<div id="__cup-wikt-banner">banner</div>
<div class="__cup_bar">bar</div>
<div class="row __cup_player_bar">player bar</div>
<div class="cup-sub-sidebar"><div class="cup-sub-cue cup-active">cue</div></div>
<div class="cup-pc cup-nolookup">picker</div>
<div id="playerTop" class="embed-responsive cup-shrink-target">the site's player</div>
<div class="cup-final cup-standings scores" data-cupid="7" data-cup-size="large">the site's own cup</div>
<a href="/channel/x" data-cup-ann="1">channel</a>
<p id="p1" class="verse" data-line="3"><span class="clickable-word cupitor-tagged cupitor-fade" data-cupitor-sent="s_1" data-cupitor-dbid="4">Han</span> <span class="clickable-word" data-cupitor-orig="gick">gikk</span> <span class="clickable-word">hem.</span></p>
<p><span class="cupitor-xform" data-cupitor-orig="färg">farg</span> <span class="cupitor-mask">[mask]</span><span class="clickable-word cupitor-masked-out">hidden</span></p>
<p id="p2">en <mark class="_fh" style="background:#ffeb3b">sökt</mark> rad</p>
</body></html>`;

const results = [];
function check(name, fn) {
  try { fn(); results.push({ name, ok: true }); }
  catch (e) { results.push({ name, ok: false, err: e }); }
}
function eq(actual, expected, what) {
  if (actual !== expected) {
    throw new Error(`${what || 'value'}\n    expected: ${JSON.stringify(expected)}\n    actual:   ${JSON.stringify(actual)}`);
  }
}
function has(hay, needle, what) {
  if (!hay.includes(needle)) throw new Error(`${what || 'output'} should contain ${JSON.stringify(needle)}`);
}
function lacks(hay, needle, what) {
  if (hay.includes(needle)) throw new Error(`${what || 'output'} should not contain ${JSON.stringify(needle)}`);
}

// Parse an export back into a DOM so assertions can be structural.
function reparse(html) {
  return new JSDOM(html).window.document;
}

check('strip: wrapped words are unwrapped and merged back into their sentence', () => {
  const out = page(INJECTED_PAGE).window.__cupitorExportHtml(true);
  const doc = reparse(out);
  const p = doc.getElementById('p1');
  eq(p.childNodes.length, 1, 'text nodes in the paragraph');
  eq(p.textContent, 'Han gick hem.');
  lacks(out, 'clickable-word');
});

check('strip: a transformed word comes back as its original', () => {
  const out = page(INJECTED_PAGE).window.__cupitorExportHtml(true);
  has(out, 'färg');
  lacks(out, 'farg');
  lacks(out, 'cupitor-xform');
});

check('strip: injected elements are gone', () => {
  const out = page(INJECTED_PAGE).window.__cupitorExportHtml(true);
  lacks(out, '__cupitor_st_styles');
  lacks(out, 'data-cupitor-injected');
  lacks(out, 'filter:none');
  lacks(out, '__cup-wikt-banner');
  lacks(out, '__cup_bar');
  lacks(out, '[mask]');
  lacks(out, 'cupitor-mask');
});

check('strip: marks on the site\'s own elements are gone, the elements stay', () => {
  const out = page(INJECTED_PAGE).window.__cupitorExportHtml(true);
  const doc = reparse(out);
  eq(doc.body.getAttribute('class'), 'theme', 'body class');
  const p = doc.getElementById('p1');
  eq(p.getAttribute('class'), 'verse', 'paragraph class');
  eq(p.getAttribute('data-line'), '3', 'the site\'s own data attribute');
  lacks(out, 'cupitor-');
  lacks(out, 'data-cupitor-');
});

check('strip: the site\'s own scripts and title survive', () => {
  const out = page(INJECTED_PAGE).window.__cupitorExportHtml(true);
  has(out, 'window.site = 1;');
  has(out, '<title>Kalinka</title>');
  has(out, 'hidden');
});

check('strip: the remote snippet\'s panels go, the site\'s own player stays', () => {
  const out = page(INJECTED_PAGE).window.__cupitorExportHtml(true);
  const doc = reparse(out);
  has(out, "the site's player", 'the element the snippet only marked');
  eq(doc.getElementById('playerTop').getAttribute('class'), 'embed-responsive',
    'the snippet\'s marker class is gone, the site\'s class stays');
  eq(doc.body.getAttribute('class'), 'theme', 'body class');
  lacks(out, 'cup-sub');
  lacks(out, 'cup-shrink-target');
  lacks(out, 'cup-nolookup');
  lacks(out, 'picker');
  lacks(out, 'position: fixed', 'the snippet\'s unmarked panel stylesheet');
  lacks(out, 'data-cup-ann');
});

check('strip: page zoom and the split height go, the rest of the style is untouched', () => {
  const doc = reparse(page(INJECTED_PAGE).window.__cupitorExportHtml(true));
  const style = doc.documentElement.getAttribute('style') || '';
  lacks(style, 'zoom: 1.15', '<html> style');
  // A semicolon inside a url() does not end a declaration, and a property
  // the engine never parsed is still the site's.
  has(style, "url('a;zoom:b.png')", '<html> style');
  has(style, '-moz-box-orient: vertical', '<html> style');
  has(style, 'color: red', '<html> style');
  lacks(doc.body.getAttribute('style') || '', 'vid-h', 'body style');
});

check('strip: marks on <html> itself are taken off too', () => {
  const doc = reparse(page(INJECTED_PAGE).window.__cupitorExportHtml(true));
  eq(doc.documentElement.getAttribute('class'), 'no-js', '<html> class');
  eq(doc.documentElement.hasAttribute('data-cupitor-lang'), false, '<html> data attribute');
});

check('strip: the site\'s own markup that merely looks like Cupitor\'s is left alone', () => {
  const out = page(INJECTED_PAGE).window.__cupitorExportHtml(true);
  const doc = reparse(out);
  const own = doc.querySelector('.scores');
  eq(own.getAttribute('class'), 'cup-final cup-standings scores', 'the site\'s cup- classes');
  eq(own.getAttribute('data-cupid'), '7', 'the site\'s data-cupid');
  eq(own.getAttribute('data-cup-size'), 'large', 'the site\'s data-cup- attribute');
  // A stylesheet that merely names something cup-ish is the site's.
  has(out, '.cup-pcs { margin: 0 }');
  has(out, '.hero { color: red }');
});

check('strip: find-in-page highlights are unwrapped, the words stay', () => {
  const out = page(INJECTED_PAGE).window.__cupitorExportHtml(true);
  const doc = reparse(out);
  eq(doc.getElementById('p2').textContent, 'en sökt rad');
  lacks(out, '_fh');
  lacks(out, '#ffeb3b');
});

check('the file is declared UTF-8, whatever the page said', () => {
  for (const strip of [true, false]) {
    const doc = reparse(page(INJECTED_PAGE).window.__cupitorExportHtml(strip));
    const first = doc.head.firstElementChild;
    eq(first.tagName, 'META', `first head child (strip=${strip})`);
    eq(first.getAttribute('charset'), 'utf-8', 'charset');
    eq(doc.head.querySelectorAll('meta[charset]').length, 1, 'charset meta count');
    eq(doc.head.querySelector('meta[charset="iso-8859-1"]'), null, 'the page\'s own charset');
  }
});

check('a Content-Type meta is replaced too', () => {
  const out = page('<!DOCTYPE html><html><head><meta http-equiv="Content-Type" content="text/html; charset=windows-1252"></head><body>å</body></html>')
    .window.__cupitorExportHtml(true);
  lacks(out, 'windows-1252');
  has(out, '<meta charset="utf-8">');
});

check('a <base> pointing at the page url follows the charset, stripped or not', () => {
  for (const strip of [true, false]) {
    const doc = reparse(page(INJECTED_PAGE).window.__cupitorExportHtml(strip));
    const base = doc.head.querySelector('base');
    eq(base.previousElementSibling.tagName, 'META', `base follows the charset (strip=${strip})`);
    eq(base.getAttribute('href'), 'https://example.test/book/ch1?x=1', 'base href');
  }
});

check('a <base> without an href does not count as the page\'s own', () => {
  const doc = reparse(page('<!DOCTYPE html><html><head><base target="_blank"></head><body>x</body></html>')
    .window.__cupitorExportHtml(true));
  eq(doc.head.querySelector('base[href]').getAttribute('href'),
    'https://example.test/book/ch1?x=1', 'base href');
});

check('no strip: every injection survives', () => {
  const out = page(INJECTED_PAGE).window.__cupitorExportHtml(false);
  has(out, '__cupitor_st_styles');
  has(out, 'data-cupitor-injected');
  has(out, '__cup-wikt-banner');
  has(out, 'class="__cup_bar"');
  has(out, '__cup_player_bar');
  has(out, 'clickable-word');
  has(out, 'cupitor-mask');
  has(out, 'cupitor-filter-active');
  has(out, 'data-cupitor-orig="gick"');
  has(out, 'cup-sub-sidebar');
  has(out, 'cup-shrink-target');
  has(out, 'data-cup-ann');
  has(out, 'class="_fh"');
  has(out, 'zoom: 1.15');
});

check('the doctype is kept', () => {
  const out = page(INJECTED_PAGE).window.__cupitorExportHtml(true);
  eq(out.startsWith('<!DOCTYPE html>\n<html'), true, 'starts with the doctype');
});

check('an XHTML doctype keeps its identifiers', () => {
  const out = page('<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd"><html><head></head><body>x</body></html>')
    .window.__cupitorExportHtml(true);
  eq(out.startsWith('<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">\n'),
    true, 'doctype line');
});

check('the live document is untouched by a stripped export', () => {
  const dom = page(INJECTED_PAGE);
  const before = dom.window.document.documentElement.outerHTML;
  dom.window.__cupitorExportHtml(true);
  eq(dom.window.document.documentElement.outerHTML, before, 'live outerHTML');
  eq(dom.window.document.querySelectorAll('.clickable-word').length, 4, 'live word spans');
});

check('a page with its own <base> keeps it', () => {
  const out = page('<!DOCTYPE html><html><head><base href="https://cdn.test/"></head><body>x</body></html>')
    .window.__cupitorExportHtml(true);
  const doc = reparse(out);
  eq(doc.querySelectorAll('base').length, 1, 'base count');
  eq(doc.querySelector('base').getAttribute('href'), 'https://cdn.test/');
});

check('a document without <head> gets one holding the <base>', () => {
  const dom = new JSDOM('<!DOCTYPE html><html><body>x</body></html>',
    { runScripts: 'outside-only', url: 'https://example.test/' });
  // jsdom, like a browser, always builds a <head>; remove it to model a
  // clone that has none.
  dom.window.document.head.remove();
  dom.window.eval(PAGE_EXPORT_JS);
  const doc = reparse(dom.window.__cupitorExportHtml(false));
  eq(doc.head.querySelector('base').getAttribute('href'), 'https://example.test/');
  eq(doc.body.textContent, 'x');
});

let failed = 0;
for (const r of results) {
  if (r.ok) console.log(`  ok   ${r.name}`);
  else { failed++; console.log(`  FAIL ${r.name}\n    ${String(r.err && r.err.message || r.err).replace(/\n/g, '\n    ')}`); }
}
console.log(`\n${results.length - failed}/${results.length} passed`);
process.exit(failed ? 1 : 0);
