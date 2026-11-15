const assert = require('node:assert/strict');
const {readFileSync} = require('node:fs');
const path = require('node:path');
const {test, before, after} = require('node:test');
const {chromium} = require('playwright-core');

const script = readFileSync(path.join(__dirname, '../../assets/js/filmot_capture.js'), 'utf8');
const video = `
  <div id="divVideoDetails">
    <div class="col-6">Video title</div>
    <a href="/channel/example">Example channel</a>
  </div>
  <iframe id="player" src="https://www.youtube.com/embed/example123"></iframe>`;
const captions = `
  <div id="subtitlesIn">
    <div id="s11"><a href="javascript:jtt(11,1.5)">▶</a> glad över att det hade ansetts</div>
    <section><div id="s12"><a href="#" onclick="jtt(12, '4.25')">▶</a> att lida smälek</div></section>
    <div id="s13"><a href="#" onclick="jtt(13, 7)">mina vänner</a></div>
  </div>`;

let browser, page;
before(async () => {
  browser = await chromium.launch({
    executablePath: process.env.CUPITOR_CHROME_PATH || '/usr/bin/google-chrome',
    headless: true,
    args: ['--no-sandbox'],
  });
  page = await browser.newPage();
  await page.route('**/*', route => {
    const url = new URL(route.request().url());
    let body = '';
    if (url.hostname === 'filmot.com') {
      if (url.pathname.endsWith('/frame')) body = video + '<iframe src="/captions"></iframe>';
      else if (url.pathname === '/captions') body = captions;
      else if (url.pathname.endsWith('/external')) body = '<iframe src="https://other.example/detail"></iframe>';
      else if (!url.pathname.endsWith('/empty')) body = video + captions;
    } else if (url.hostname === 'other.example') {
      body = video + captions;
    }
    return route.fulfill({contentType: 'text/html; charset=utf-8', body: '<!doctype html>' + body});
  });
});
after(async () => { await browser?.close(); });

async function capture(url) {
  await page.goto(url);
  const result = await page.evaluate(script);
  return result === null ? null : JSON.parse(result);
}

test('captures timed legacy, nested, and linked subtitle rows', async () => {
  const result = await capture('https://filmot.com/search/%22sm%C3%A4lek%22/1');
  assert.equal(result.query, 'smälek');
  assert.equal(result.videoId, 'example123');
  assert.equal(result.videoTitle, 'Video title');
  assert.equal(result.videoChannel, 'Example channel');
  assert.equal(result.matchIdx, 1);
  assert.deepEqual(result.lines, [
    {i: 11, ts: 1.5, t: 'glad över att det hade ansetts'},
    {i: 12, ts: 4.25, t: 'att lida smälek'},
    {i: 13, ts: 7, t: 'mina vänner'},
  ]);
});

test('reads a same-origin detail frame while retaining the parent search query', async () => {
  const result = await capture('https://filmot.com/search/%22sm%C3%A4lek%22/1/frame');
  assert.equal(result.query, 'smälek');
  assert.equal(result.videoId, 'example123');
  assert.equal(result.videoTitle, 'Video title');
  assert.equal(result.videoChannel, 'Example channel');
  assert.equal(result.lines.length, 3);
  assert.equal(result.matchIdx, 1);
});

test('unrelated frames and pages and unloaded captions produce no capture', async () => {
  assert.equal(await capture('https://other.example/detail'), null);
  assert.deepEqual((await capture('https://filmot.com/search/word/1/external')).lines, []);
  assert.deepEqual((await capture('https://filmot.com/search/word/1/empty')).lines, []);
});
