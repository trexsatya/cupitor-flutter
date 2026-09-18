#!/usr/bin/env node
// Behavioural tests for the text a sentence capture hands to the tag sheet,
// on both surfaces: assets/js/sentence_tag.js (web pages) and the EPUB
// reader's script, which lives inside lib/epub_reader.dart as the Dart
// string `_epubTagHelpersJs` and is extracted from there at run time.
//
// The contract under test: whitespace reaches the sheet as the reader saw
// it. A line break that is rendered — a <br>, the edge of a block, a newline
// inside preformatted text — survives as '\n'; a newline that only exists in
// the HTML source collapses to a space; nothing is inserted where the page
// had no whitespace at all, so fingerprints and rehydration are unaffected.
//
// Runs on Node with jsdom. This repo has no package.json, so jsdom is taken
// from the webapp checkout beside it, or from $CUPITOR_JSDOM.
//
//   node tools/sentence_text_test.js
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

// ---- scripts under test ----

const SENTENCE_TAG_JS = fs.readFileSync(path.join(ROOT, 'assets/js/sentence_tag.js'), 'utf8');

// The EPUB script is a Dart triple-quoted string. Undo the two escapes the
// Dart source needs (`\\` and `\$`); `\u{…}` is left alone — valid in JS too.
function extractEpubJs() {
  const dart = fs.readFileSync(path.join(ROOT, 'lib/epub_reader.dart'), 'utf8');
  const startMarker = "static const String _epubTagHelpersJs = '''";
  const start = dart.indexOf(startMarker);
  if (start < 0) throw new Error('_epubTagHelpersJs not found in lib/epub_reader.dart');
  const bodyStart = start + startMarker.length;
  const end = dart.indexOf("''';", bodyStart);
  if (end < 0) throw new Error('_epubTagHelpersJs is not terminated');
  const raw = dart.substring(bodyStart, end);
  if (/(^|[^\\])\$\{/.test(raw)) throw new Error('unexpected Dart interpolation inside _epubTagHelpersJs');
  return raw.replace(/\\\\/g, '\\').replace(/\\\$/g, '$');
}
const EPUB_JS = extractEpubJs();

// ---- harness ----

function makePage(bodyHtml) {
  const dom = new JSDOM(
    `<!DOCTYPE html><html><head></head><body>${bodyHtml}</body></html>`,
    { runScripts: 'outside-only', pretendToBeVisual: true },
  );
  const { window } = dom;
  // jsdom ships neither, and _fp quietly returns '' without them — which
  // would make every fingerprint in these tests an empty string.
  if (!window.crypto) window.crypto = require('crypto').webcrypto;
  if (!window.TextEncoder) window.TextEncoder = require('util').TextEncoder;
  const queue = [];
  window.SentenceTagHandler = { postMessage: (s) => queue.push(JSON.parse(s)) };
  // Both scripts post after an await (the fingerprint), so give them a
  // few ticks rather than reading the queue synchronously.
  async function nextMessage() {
    for (let i = 0; i < 200; i++) {
      if (queue.length) return queue.shift();
      await new Promise((r) => setTimeout(r, 2));
    }
    throw new Error('no message from the script within 400ms');
  }
  return { window, document: window.document, nextMessage };
}

function eq(actual, expected, what) {
  if (actual !== expected) {
    throw new Error(
      `${what || 'value'}\n    expected: ${JSON.stringify(expected)}\n    actual:   ${JSON.stringify(actual)}`,
    );
  }
}

const results = [];
async function check(name, fn) {
  try {
    await fn();
    results.push({ name, ok: true });
  } catch (e) {
    results.push({ name, ok: false, err: e });
  }
}

// ---- web surface (assets/js/sentence_tag.js) ----

// utils.js wraps every word in one of these; the script routes taps by them.
const w = (t) => `<span class="clickable-word">${t}</span>`;

async function webCapture(bodyHtml, tapWord, extendDirs = [], opts = {}) {
  const page = makePage(bodyHtml);
  page.window.eval(SENTENCE_TAG_JS);
  // 'document' is the mode for sites that print each line in its own
  // block; the default 'block' segments the tapped word's nearest block.
  if (opts.scope) page.window.__cupitorSetSegmentationScope(opts.scope);
  const span = Array.from(page.document.querySelectorAll('.clickable-word'))
    .find((s) => s.textContent === tapWord);
  if (!span) throw new Error(`no word span "${tapWord}" in the page`);
  page.window.__cupitorOnWordTap(span);
  let msg = await page.nextMessage();
  eq(msg.op, 'capture', 'op');
  for (const dir of extendDirs) {
    page.window.__cupitorRequestExtend(msg.sentenceId, dir);
    msg = await page.nextMessage();
    eq(msg.op, 'extend', 'op');
  }
  return msg.text;
}

async function webTests() {
  // litteraturbanken's shape: each printed line is its own block-styled
  // span, with the source newline sitting between them. The lines carry
  // no terminator, so the segmenter merges them into one sentence — and
  // the reader saw two lines.
  await check('web: lines in display:block spans keep their line break', async () => {
    const text = await webCapture(
      `<div><span style="display:block">${w('Line')} ${w('one')}</span>
<span style="display:block">${w('Line')} ${w('two.')}</span></div>`,
      'one',
    );
    eq(text, 'Line one\nLine two.');
  });

  // Google Docs' shape: every line of the transcript is its own <p>, and the
  // HTML has no whitespace whatsoever between </p> and the next <p>.
  await check('web: paragraphs that abut with no whitespace still break', async () => {
    const text = await webCapture(
      `<div><p>${w('Han')} ${w('gick')} ${w('hem,')}</p><p>${w('sa')} ${w('hon.')}</p></div>`,
      'gick',
      [],
      { scope: 'document' },
    );
    eq(text, 'Han gick hem,\nsa hon.');
  });

  // With nothing between the paragraphs the segmenter cannot see a sentence
  // boundary there either, so one capture already spans both lines and Next
  // reaches over the paragraph edge. The break has to survive that too.
  await check('web: Next reaching over a paragraph edge keeps the break', async () => {
    const text = await webCapture(
      `<div><p>${w('Ett.')} ${w('Tva.')}</p><p>${w('Tre.')}</p></div>`,
      'Ett.',
      ['next'],
      { scope: 'document' },
    );
    eq(text, 'Ett. Tva.\nTre.');
  });

  await check('web: a <br> with no whitespace around it becomes a line break', async () => {
    const text = await webCapture(
      `<p>${w('Rose')} ${w('red')}<br>${w('Violet')} ${w('blue.')}</p>`,
      'red',
    );
    eq(text, 'Rose red\nViolet blue.');
  });

  await check('web: words that merely abut inline stay joined', async () => {
    const text = await webCapture(
      `<p>${w('Han')} ${w('gick')} <b>${w('hem')}</b>${w('.')}</p>`,
      'gick',
    );
    eq(text, 'Han gick hem.');
  });

  await check('web: a <br> with whitespace around it becomes a line break', async () => {
    const text = await webCapture(
      `<p>${w('Rose')} ${w('red')} <br>
${w('Violet')} ${w('blue.')}</p>`,
      'red',
    );
    eq(text, 'Rose red\nViolet blue.');
  });

  await check('web: a newline inside preformatted text is kept', async () => {
    const text = await webCapture(
      `<pre>${w('alpha')}\n${w('beta.')}</pre>`,
      'alpha',
    );
    eq(text, 'alpha\nbeta.');
  });

  await check('web: white-space: pre-wrap counts as preformatted', async () => {
    const text = await webCapture(
      `<div style="white-space: pre-wrap">${w('alpha')}\n${w('beta.')}</div>`,
      'alpha',
    );
    eq(text, 'alpha\nbeta.');
  });

  // The twin: a newline that is only source formatting renders as a space
  // and must arrive as one.
  await check('web: a source-only newline inside a paragraph is a space', async () => {
    const text = await webCapture(
      `<p>${w('Some')} ${w('long')}
${w('sentence')} ${w('here.')}</p>`,
      'long',
    );
    eq(text, 'Some long sentence here.');
  });

  await check('web: runs of spaces collapse to one', async () => {
    const text = await webCapture(
      `<p>${w('One')}    ${w('two.')}</p>`,
      'One',
    );
    eq(text, 'One two.');
  });

  await check('web: two sentences in one paragraph join with a space', async () => {
    const text = await webCapture(
      `<p>${w('One.')} ${w('Two.')}</p>`,
      'One.',
      ['next'],
    );
    eq(text, 'One. Two.');
  });


  await check('web: a word the reader cannot see is not part of the sentence', async () => {
    const text = await webCapture(
      `<p>${w('Han')} <span class="clickable-word" style="visibility:hidden">DOLD</span> ` +
        `${w('gick')} ${w('hem.')}</p>`,
      'Han',
    );
    eq(text, 'Han gick hem.');
  });

  // Some sites print one word per line by making the word span itself the
  // block.
  await check('web: a word span that is its own line keeps the break', async () => {
    const text = await webCapture(
      `<p><span class="clickable-word" style="display:block">Line</span>` +
        `<span class="clickable-word" style="display:block">two.</span></p>`,
      'Line',
    );
    eq(text, 'Line\ntwo.');
  });

  // Cells keep their own box, so the reader reads a gap between them even
  // when the markup runs them together — the same shape as a line break
  // with no whitespace, one step smaller.
  await check('web: cells that abut with no whitespace still read apart', async () => {
    const text = await webCapture(
      `<table><tr><td>${w('Ett')}</td><td>${w('tva.')}</td></tr></table>`,
      'Ett',
      [],
      { scope: 'document' },
    );
    eq(text, 'Ett tva.');
  });

  // A browser blockifies the children of a flex container, so their own
  // display says 'block' even though they sit side by side in a row.
  await check('web: items in a flex row share a line', async () => {
    const text = await webCapture(
      `<div style="display:flex"><span style="display:block">${w('One')}</span> ` +
        `<span style="display:block">${w('two.')}</span></div>`,
      'One',
    );
    eq(text, 'One two.');
  });

  await check('web: items in a flex column are each their own line', async () => {
    const text = await webCapture(
      `<div style="display:flex;flex-direction:column"><span style="display:block">${w('One')}</span> ` +
        `<span style="display:block">${w('two.')}</span></div>`,
      'One',
    );
    eq(text, 'One\ntwo.');
  });

  // The layout engine outranks the tag: a block tag the reader cannot see
  // is not a line.
  await check('web: a hidden block element between sentences is not a line break', async () => {
    const text = await webCapture(
      `<div>${w('One.')} <p style="display:none"></p> ${w('Two.')}</div>`,
      'One.',
      ['next'],
    );
    eq(text, 'One. Two.');
  });

  await check('web: list items styled inline stay on one line (document scope)', async () => {
    const text = await webCapture(
      `<ul><li style="display:inline">${w('A.')}</li> <li style="display:inline">${w('B.')}</li></ul>`,
      'A.',
      ['next'],
      { scope: 'document' },
    );
    eq(text, 'A. B.');
  });

  await check('web: cells of one table row share a line (document scope)', async () => {
    const text = await webCapture(
      `<table><tr><td>${w('A')}</td> <td>${w('B.')}</td></tr></table>`,
      'A',
      [],
      { scope: 'document' },
    );
    eq(text, 'A B.');
  });

  // litteraturbanken proper: per-line block spans with the whole page as
  // the segmentation scope.
  await check('web: per-line blocks keep their breaks in document scope', async () => {
    const text = await webCapture(
      `<div><span style="display:block">${w('Line')} ${w('one')}</span>
<span style="display:block">${w('Line')} ${w('two.')}</span></div>`,
      'one',
      [],
      { scope: 'document' },
    );
    eq(text, 'Line one\nLine two.');
  });
}

// ---- EPUB surface (lib/epub_reader.dart → _epubTagHelpersJs) ----

// The reader wraps each sentence in one of these before capture runs.
const cs = (n, t) => `<span class="cup-sent" data-sent="${n}">${t}</span>`;

async function epubCapture(bodyHtml, tapIndex, extendDirs = []) {
  const page = makePage(bodyHtml);
  page.window.eval(EPUB_JS);
  const span = page.document.querySelector(`.cup-sent[data-sent="${tapIndex}"]`);
  if (!span) throw new Error(`no .cup-sent[data-sent="${tapIndex}"] in the page`);
  page.window.__cupitorOnEpubSentenceTap({
    target: span, preventDefault() {}, stopPropagation() {},
  });
  let msg = await page.nextMessage();
  eq(msg.op, 'capture', 'op');
  for (const dir of extendDirs) {
    page.window.__cupitorRequestExtend(msg.sentenceId, dir);
    msg = await page.nextMessage();
    eq(msg.op, 'extend', 'op');
  }
  return msg.text;
}

// ---- rehydration (assets/js/sentence_tag.js) ----

// Paint a set of stored records onto a page and report, per word, which
// record ids claimed it.
async function webRehydrate(bodyHtml, records, opts = {}) {
  const page = makePage(bodyHtml);
  page.window.eval(SENTENCE_TAG_JS);
  if (opts.scope) page.window.__cupitorSetSegmentationScope(opts.scope);
  await page.window.__cupitorApplyTags(JSON.stringify(records));
  const out = {};
  const seq = [];
  for (const el of page.document.querySelectorAll('.clickable-word')) {
    const dbid = el.getAttribute('data-cupitor-dbid');
    seq.push(dbid ? dbid.split(',') : []);
    if (dbid) out[el.textContent] = (out[el.textContent] || []).concat(dbid.split(','));
  }
  out.__seq = seq;
  return out;
}

// Capture once and hand back the payload the app would store.
async function webRecord(bodyHtml, tapWord, id, opts = {}) {
  const page = makePage(bodyHtml);
  page.window.eval(SENTENCE_TAG_JS);
  if (opts.scope) page.window.__cupitorSetSegmentationScope(opts.scope);
  const hits = Array.from(page.document.querySelectorAll('.clickable-word'))
    .filter((s) => s.textContent === tapWord);
  const span = hits[opts.nth || 0];
  if (!span) throw new Error(`no word span "${tapWord}" #${opts.nth || 0}`);
  page.window.__cupitorOnWordTap(span);
  let msg = await page.nextMessage();
  for (const dir of opts.extend || []) {
    page.window.__cupitorRequestExtend(msg.sentenceId, dir);
    msg = await page.nextMessage();
  }
  return { id, text: msg.text, prevFp: msg.prevFp, nextFp: msg.nextFp, tagIds: [1], tagColors: ['#f00'] };
}

async function epubRehydrateTests() {
  // Two records of the same refrain must take one occurrence each.
  await check('epub rehydrate: a repeated sentence gives each record its own copy', async () => {
    const page = makePage(
      `<p>${cs(0, 'Ja.')}</p><p>${cs(1, 'Ett.')}</p><p>${cs(2, 'Ja.')}</p>`);
    page.window.eval(EPUB_JS);
    page.window.__cupitorApplyTags(JSON.stringify([
      { id: 11, text: 'Ja.', tagIds: [1], tagColors: ['#f00'] },
      { id: 12, text: 'Ja.', tagIds: [2], tagColors: ['#0f0'] },
    ]));
    const stamped = Array.from(page.document.querySelectorAll('.cup-sent'))
      .map((el) => el.getAttribute('data-cupitor-dbid') || '');
    eq(stamped[0], '11', 'the first Ja.');
    eq(stamped[2], '12', 'the second Ja.');
  });

  // The wrapper leaves punctuation stranded in its own span — a dash, the
  // full stop after an italic word. A run beginning there is the same run
  // as the one beginning after it, so it must not be what gets claimed.
  await check('epub rehydrate: a punctuation-only span does not misdirect the claim', async () => {
    const page = makePage(
      `<p>${cs(0, '\u2014')}${cs(1, 'Ja.')}</p><p>${cs(2, '\u2014')}${cs(3, 'Ja.')}</p>`);
    page.window.eval(EPUB_JS);
    page.window.__cupitorApplyTags(JSON.stringify([
      { id: 61, text: 'Ja.', tagIds: [1], tagColors: ['#f00'] },
      { id: 62, text: 'Ja.', tagIds: [2], tagColors: ['#0f0'] },
    ]));
    const stamped = Array.from(page.document.querySelectorAll('.cup-sent'))
      .map((el) => el.getAttribute('data-cupitor-dbid') || '');
    eq(stamped[1], '61', 'the first Ja.');
    eq(stamped[3], '62', 'the second Ja.');
    eq(stamped[0], '', 'the dash is not part of the first record');
  });
}

async function rehydrateTests() {
  // litteraturbanken's shape, where the two scopes read a page differently.
  const LINES =
    `<div><span style="display:block">${w('Line')} ${w('one')}</span>\n` +
    `<span style="display:block">${w('Line')} ${w('two.')}</span></div>`;

  await check('rehydrate: a record stored in block scope still paints in document scope', async () => {
    const rec = await webRecord(LINES, 'one', 7, { scope: 'block' });
    const painted = await webRehydrate(LINES, [rec], { scope: 'document' });
    eq(Object.keys(painted).length > 0, true, `block-scope record painted nothing: ${rec.text}`);
    eq((painted['one'] || []).includes('7'), true, 'the tapped word carries the record');
  });

  await check('rehydrate: a record stored in document scope still paints in block scope', async () => {
    const rec = await webRecord(LINES, 'one', 8, { scope: 'document' });
    const painted = await webRehydrate(LINES, [rec], { scope: 'block' });
    eq((painted['one'] || []).includes('8'), true, 'the tapped word carries the record');
  });

  // The same sentence printed twice on one page. The two records differ
  // only in their neighbours, which is what has to tell them apart.
  await check('rehydrate: a repeated sentence gives each record its own occurrence', async () => {
    const page = `<div><p>${w('Ja.')} ${w('Ett.')}</p>\n<p>${w('Ja.')} ${w('Tva.')}</p></div>`;
    const first = await webRecord(page, 'Ja.', 11, { scope: 'document', nth: 0 });
    const second = await webRecord(page, 'Ja.', 12, { scope: 'document', nth: 1 });
    eq(first.text, second.text, 'the two readings are the same text');
    eq(first.nextFp === second.nextFp, false, 'their neighbours differ');
    const painted = await webRehydrate(page, [first, second], { scope: 'document' });
    // Word order: Ja. Ett. Ja. Tva.
    eq(painted.__seq[0].join(), '11', 'the first Ja. is the first record');
    eq(painted.__seq[2].join(), '12', 'the second Ja. is the second record');
  });

  // A capture extended with Next spans several sentences, and that whole
  // run is what was stored.
  await check('rehydrate: a capture extended with Next paints again', async () => {
    const page = `<p>${w('Han')} ${w('gick')} ${w('hem.')} ${w('Hon')} ${w('kom')} ${w('hit.')}</p>`;
    const rec = await webRecord(page, 'Han', 31, { extend: ['next'] });
    eq(rec.text, 'Han gick hem. Hon kom hit.');
    const painted = await webRehydrate(page, [rec]);
    eq((painted['hit.'] || []).includes('31'), true, 'the far end of the run is painted');
    eq((painted['Han'] || []).includes('31'), true, 'the near end of the run is painted');
  });

  // A hidden copy of the same sentence must not steal the paint from the
  // one the reader can see.
  await check('rehydrate: a sentence inside a hidden container is not a candidate', async () => {
    const visible = `<p>${w('Han')} ${w('gick')} ${w('hem.')}</p>`;
    const withHiddenCopy =
      `<div style="display:none"><p>${w('Han')} ${w('gick')} ${w('hem.')}</p></div>` + visible;
    const rec = await webRecord(visible, 'gick', 41);
    for (const scope of ['block', 'document']) {
      const painted = await webRehydrate(withHiddenCopy, [rec], { scope });
      // Word order: hidden Han gick hem., then the visible three.
      eq(painted.__seq[1].join(), '', `the hidden copy was painted (scope=${scope})`);
      eq(painted.__seq[4].join(), '41', `the visible sentence was not painted (scope=${scope})`);
    }
  });

  // When the neighbours are identical too, the fingerprints cannot choose
  // and only "this occurrence is already taken" can.
  await check('rehydrate: identical surroundings still give each record its own copy', async () => {
    const page = `<div><p>${w('Ett.')} ${w('Ja.')} ${w('Ett.')}</p>\n` +
      `<p>${w('Ett.')} ${w('Ja.')} ${w('Ett.')}</p></div>`;
    const first = await webRecord(page, 'Ja.', 21, { scope: 'document', nth: 0 });
    const second = await webRecord(page, 'Ja.', 22, { scope: 'document', nth: 1 });
    eq(first.prevFp === second.prevFp && first.nextFp === second.nextFp, true,
      'the two readings are indistinguishable by fingerprint');
    const painted = await webRehydrate(page, [first, second], { scope: 'document' });
    // Word order: Ett. Ja. Ett. | Ett. Ja. Ett.
    eq(painted.__seq[1].join(), '21', 'the first Ja.');
    eq(painted.__seq[4].join(), '22', 'the second Ja.');
  });

  // Hidden text is not part of the sentence, so a record stays paintable
  // whatever the page keeps out of sight.
  await check('rehydrate: hidden text is ignored on both sides', async () => {
    const visible = `<p>${w('Han')} ${w('gick')} ${w('hem.')}</p>`;
    const withHidden =
      `<p>${w('Han')} <span style="display:none">${w('DEBUG')}</span> ${w('gick')} ${w('hem.')}</p>`;
    const rec = await webRecord(visible, 'gick', 21);
    eq(rec.text, 'Han gick hem.');
    const painted = await webRehydrate(withHidden, [rec]);
    eq((painted['gick'] || []).includes('21'), true, 'the record found its sentence');
    eq(painted['DEBUG'], undefined, 'the hidden word was not painted');
  });
}

async function epubTests() {
  await check('epub: sentences in separate paragraphs join with a line break', async () => {
    const text = await epubCapture(
      `<p>${cs(0, 'Line one')}</p>
<p>${cs(1, 'Line two.')}</p>`,
      0,
      ['next'],
    );
    eq(text, 'Line one\nLine two.');
  });

  await check('epub: sentences split by <br> join with a line break', async () => {
    const text = await epubCapture(
      `<p>${cs(0, 'Rose red')}<br>${cs(1, 'Violet blue.')}</p>`,
      0,
      ['next'],
    );
    eq(text, 'Rose red\nViolet blue.');
  });

  await check('epub: verse lines in display:block spans join with a line break', async () => {
    const text = await epubCapture(
      `<div><span style="display:block">${cs(0, 'A')}</span><span style="display:block">${cs(1, 'B.')}</span></div>`,
      0,
      ['next'],
    );
    eq(text, 'A\nB.');
  });

  await check('epub: sentences in one paragraph join with a space', async () => {
    const text = await epubCapture(
      `<p>${cs(0, 'One. ')}${cs(1, 'Two.')}</p>`,
      0,
      ['next'],
    );
    eq(text, 'One. Two.');
  });

  // Inside one sentence a newline is source formatting; the reader saw a
  // space.
  await check('epub: a source newline inside one sentence is a space', async () => {
    const text = await epubCapture(
      `<p>${cs(0, 'Some long\n   sentence.')}</p>`,
      0,
    );
    eq(text, 'Some long sentence.');
  });

  await check('epub: extending backwards across a paragraph also breaks the line', async () => {
    const text = await epubCapture(
      `<p>${cs(0, 'First.')}</p><p>${cs(1, 'Second.')}</p>`,
      1,
      ['prev'],
    );
    eq(text, 'First.\nSecond.');
  });

  // The break exists only because the first span's paragraph closes; the
  // second span sits in bare text with no wrapper of its own.
  await check('epub: a paragraph followed by bare text still breaks the line', async () => {
    const text = await epubCapture(
      `<p>${cs(0, 'First.')}</p>${cs(1, 'Second.')}`,
      0,
      ['next'],
    );
    eq(text, 'First.\nSecond.');
  });

  // The wrapper splits a sentence at every inline element, so the pieces
  // must be rejoined exactly as the markup had them — no gap invented at
  // an <em>, none lost either.
  await check('epub: an inline element inside a sentence adds no space', async () => {
    const text = await epubCapture(
      `<p>${cs(0, 'Han gick ')}<em>${cs(1, 'hem')}</em>${cs(2, '.')}</p>`,
      0,
      ['next', 'next'],
    );
    eq(text, 'Han gick hem.');
  });

  await check('epub: a footnote marker does not gain spaces around it', async () => {
    const text = await epubCapture(
      `<p>${cs(0, 'Han gick hem')}<sup>${cs(1, '1')}</sup>${cs(2, ' och sov.')}</p>`,
      0,
      ['next', 'next'],
    );
    eq(text, 'Han gick hem1 och sov.');
  });

  // Hidden matter between two sentence spans is not a word gap the reader
  // sees.
  await check('epub: a hidden block between sentences adds no space', async () => {
    const text = await epubCapture(
      `<div>${cs(0, 'One.')}<div style="display:none"> note </div>${cs(1, 'Two.')}</div>`,
      0,
      ['next'],
    );
    eq(text, 'One.Two.');
  });

  // The mirror of the web case: paragraphs written with nothing at all
  // between them.
  await check('epub: paragraphs that abut with no whitespace still break', async () => {
    const text = await epubCapture(
      `<p>${cs(0, 'First.')}</p><p>${cs(1, 'Second.')}</p>`,
      0,
      ['next'],
    );
    eq(text, 'First.\nSecond.');
  });

  await check('epub: a hidden block between sentences is not a line break', async () => {
    const text = await epubCapture(
      `<div>${cs(0, 'One.')} <div style="display:none">note</div> ${cs(1, 'Two.')}</div>`,
      0,
      ['next'],
    );
    eq(text, 'One. Two.');
  });

  await check('epub: cells of one table row share a line', async () => {
    const text = await epubCapture(
      `<table><tr><td>${cs(0, 'A.')}</td><td>${cs(1, 'B.')}</td></tr></table>`,
      0,
      ['next'],
    );
    eq(text, 'A. B.');
  });
}

(async () => {
  await webTests();
  await epubTests();
  await rehydrateTests();
  await epubRehydrateTests();
  let failed = 0;
  for (const r of results) {
    if (r.ok) {
      console.log(`  ok   ${r.name}`);
    } else {
      failed++;
      console.log(`  FAIL ${r.name}\n    ${String(r.err && r.err.message || r.err).replace(/\n/g, '\n    ')}`);
    }
  }
  console.log(`\n${results.length - failed}/${results.length} passed`);
  process.exit(failed ? 1 : 0);
})().catch((e) => {
  console.error(e);
  process.exit(2);
});
