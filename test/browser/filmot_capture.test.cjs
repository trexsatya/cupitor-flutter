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
const mobileCaptions = `
  <div class="scroll-subtitles">
    <div id="s21"><div><a id="seek-21" href="javascript:jtt(21,42.5);">▶&nbsp;</a></div>
      <span>jag tycker att beskäftig är ett bra ord</span>
    </div>
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
      else if (url.pathname.endsWith('/mobile')) body = mobileCaptions;
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

test('reads a mobile transcript and identifies its video from the current result URL', async () => {
  const result = await capture('https://filmot.com/search/%22besk%C3%A4ftig%22/example1234/1/mobile');
  assert.equal(result.query, 'beskäftig');
  assert.equal(result.videoId, 'example1234');
  assert.deepEqual(result.lines, [
    {i: 21, ts: 42.5, t: 'jag tycker att beskäftig är ett bra ord'},
  ]);
});

test('sends timed captions over the dialog bridge after they load', async () => {
  await page.goto('https://filmot.com/search/%22sm%C3%A4lek%22/1/empty');
  await page.evaluate(() => {
    window.captureReplies = [];
    window.FilmotBridge = {
      postMessage: value => window.captureReplies.push(JSON.parse(value)),
    };
  });
  await page.evaluate(`(function(cupitorFilmotCaptureRequestId) {
    ${script}
  })(41);
  setTimeout(() => { document.body.innerHTML = ${JSON.stringify(video + captions)}; }, 100);`);
  await page.waitForFunction(() => window.captureReplies.length > 0, null, {timeout: 3000});
  const [reply] = await page.evaluate(() => window.captureReplies);
  assert.equal(reply.action, 'subtitleCapture');
  assert.equal(reply.requestId, 41);
  assert.equal(reply.capture.query, 'smälek');
  assert.equal(reply.capture.matchIdx, 1);
  assert.deepEqual(reply.capture.lines[1], {i: 12, ts: 4.25, t: 'att lida smälek'});
});
