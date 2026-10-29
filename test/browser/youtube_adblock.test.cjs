const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {test, before, after} = require('node:test');
const {chromium} = require('playwright-core');
const script = fs.readFileSync(path.join(__dirname, '../../assets/js/frame_boot.js'), 'utf8');
let browser;
before(async () => { browser = await chromium.launch({
  executablePath: process.env.CUPITOR_CHROME_PATH || '/usr/bin/google-chrome',
  headless: true, args: ['--no-sandbox'],
}); });
after(async () => { await browser?.close(); });
async function fixture(run) {
  const context = await browser.newContext();
  try {
    // Same ordering/scope as WKUserScript(.atDocumentStart, forMainFrameOnly:false).
    await context.addInitScript({content: script});
    const page = await context.newPage();
    await page.route('**/*', route => {
      const url = new URL(route.request().url());
      if (url.pathname.startsWith('/youtubei/')) return route.fulfill({
        contentType: 'application/json', body: JSON.stringify({response: {playerResponse: {
          adPlacements: [1], playerAds: [2], adSlots: [3], videoDetails: {videoId: 'abcdefghijk'},
        }}}),
      });
      return route.fulfill({contentType: 'text/html', body: url.hostname === 'www.youtube.com' ?
        '<!doctype html><script>window.ytInitialPlayerResponse = {adPlacements:[1], playerAds:[2], videoDetails:{videoId:"abcdefghijk"}}; window.pageSawAds = "adPlacements" in window.ytInitialPlayerResponse;</script><video></video>' :
        '<!doctype html><iframe src="https://www.youtube.com/embed/abcdefghijk"></iframe>'});
    });
    await page.goto('https://www.youtube.com/watch?v=abcdefghijk');
    await run(page);
  } finally { await context.close(); }
}
test('document-start pruning beats the first inline player read and retains content', async () => {
  await fixture(async page => {
    assert.equal(await page.evaluate(() => window.pageSawAds), false);
    assert.equal(await page.evaluate(() => window.ytInitialPlayerResponse.videoDetails.videoId), 'abcdefghijk');
  });
});
test('embedded YouTube gets the same pruning before its page scripts', async () => {
  await fixture(async page => {
    await page.goto('https://study.example/language.html');
    const frame = page.frames().find(f => f.url().startsWith('https://www.youtube.com/embed/'));
    assert.ok(frame);
    assert.equal(await frame.evaluate(() => window.pageSawAds), false);
    assert.equal(await frame.evaluate(() => window._ytAdPruneInstalled), 1);
  });
});
test('SPA player and mobile get_watch responses are pruned for fetch and XHR', async () => {
  await fixture(async page => {
    for (const endpoint of ['player', 'get_watch']) {
      for (const transport of ['fetch', 'xhr']) {
        const result = await page.evaluate(async ({endpoint, transport}) => {
          const url = '/youtubei/v1/' + endpoint;
          if (transport === 'fetch') return (await fetch(url)).json();
          return new Promise((resolve, reject) => {
            const xhr = new XMLHttpRequest();
            xhr.open('GET', url);
            xhr.onload = () => resolve(JSON.parse(xhr.responseText));
            xhr.onerror = reject;
            xhr.send();
          });
        }, {endpoint, transport});
        assert.deepEqual(result.response.playerResponse, {videoDetails: {videoId: 'abcdefghijk'}}, `${endpoint} ${transport}`);
      }
    }
  });
});
