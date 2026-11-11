const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {test, before, after} = require('node:test');
const {chromium} = require('playwright-core');

const reader = fs.readFileSync(path.join(__dirname, '../../lib/epub_reader.dart'), 'utf8');
const speech = fs.readFileSync(path.join(__dirname, '../../lib/epub_speech.dart'), 'utf8')
  .match(/const epubSpeechLinesJs = r'''([\s\S]*?)'''/)[1];
const chapter = reader.slice(reader.indexOf('  var sentenceCount = 0;'),
  reader.indexOf('  // ── Saved highlights:'))
  .replaceAll('\\\\', '\\').replaceAll('\\$', '$').replace('$epubSpeechLinesJs', speech);
let browser;
before(async () => {
  browser = await chromium.launch({
    executablePath: process.env.CUPITOR_CHROME_PATH || '/usr/bin/google-chrome',
    headless: true,
    args: ['--no-sandbox'],
  });
});
after(async () => { await browser?.close(); });

test('read-aloud joins inline formatting and pauses at authored lines only', async () => {
  const page = await browser.newPage({viewport: {width: 240, height: 500}});
  try {
    await page.setContent(`
      <p>Read <em>this</em> whole line with several words so it wraps
      naturally. <span hidden>Skip this.</span><br><br>After a blank line.</p>
      <div style="white-space: pre-line">Verse one
Verse two<span style="display: block">Verse three</span></div>
      <p>A new paragraph.</p>
    `);
    await page.addScriptTag({content: 'var programmaticScrollUntil = 0;\n' + chapter});
    const lines = await page.evaluate(() => JSON.parse(window.__cupEpubSpeechLines()));
    assert.deepEqual(lines.map(line => line.text), [
      'Read this whole line with several words so it wraps naturally.',
      '',
      'After a blank line.',
      'Verse one',
      'Verse two',
      'Verse three',
      'A new paragraph.',
    ]);
    assert.deepEqual(lines.map(line => line.breakAfter), [
      'newline', 'newline', 'paragraph', 'newline', 'newline', 'paragraph', null,
    ]);
    const highlighted = await page.evaluate(({start, end}) => {
      window.__cupEpubSpeakHighlight(start, end);
      return [...document.querySelectorAll('.cup-sent-current')]
        .map(span => span.textContent).join('').replace(/\s+/g, ' ').trim();
    }, lines[0]);
    assert.equal(highlighted, lines[0].text);
  } finally {
    await page.close();
  }
});

test('read from here starts at the selected occurrence and its exact offset', async () => {
  const page = await browser.newPage();
  try {
    await page.setContent('<p>repeat here.</p><p>Later, <em>repeat here</em> again.<br>Next line.</p>');
    await page.addScriptTag({content: 'var programmaticScrollUntil = 0;\n' + chapter});
    const [live, saved] = await page.evaluate(() => {
      const node = document.querySelector('em .cup-sent').firstChild;
      const range = document.createRange();
      range.setStart(node, 7);
      range.setEnd(node, 11);
      const selection = window.getSelection();
      selection.addRange(range);
      const live = JSON.parse(window.__cupEpubSpeechLines(true));
      window.__cupEpubSpeechSelection = range.cloneRange();
      selection.removeAllRanges();
      const saved = JSON.parse(window.__cupEpubSpeechLines(true));
      return [live, saved];
    });
    assert.deepEqual(live.map(line => [line.text, line.breakAfter]), [
      ['here again.', 'newline'], ['Next line.', null],
    ]);
    assert.deepEqual(saved, live);
  } finally {
    await page.close();
  }
});
