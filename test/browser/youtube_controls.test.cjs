const assert = require('node:assert/strict');
const {readFileSync} = require('node:fs');
const path = require('node:path');
const {test, before, after} = require('node:test');
const {chromium} = require('playwright-core');

// Actual cross-origin frames and Chromium's CSS cascade, with a deterministic
// player fixture. Android's document-start injection is represented by the
// same bundled script running before either document's page scripts.
const script = readFileSync(path.join(__dirname, '../../assets/js/youtube_controls.js'), 'utf8');
const playerHtml = `<!doctype html><html><body>
  <video class="html5-main-video" id="video"></video>
  <div class="ytp-chrome-top" id="top">Title</div>
  <div class="ytp-chrome-bottom" id="bottom">Controls</div>
  <div class="ytp-pause-overlay" id="pause">Pause overlay</div>
  <div class="ytp-caption-window-container" id="captions">Captions</div>
  <div class="ytp-error" id="error">Error</div>
  <div class="ytp-spinner" id="spinner">Loading</div>
</body></html>`;
let browser;
before(async () => {
  browser = await chromium.launch({
    executablePath: process.env.CUPITOR_CHROME_PATH || '/usr/bin/google-chrome',
    headless: true, args: ['--no-sandbox']
  });
});
after(async () => { await browser?.close(); });

async function fixture(run) {
  const context = await browser.newContext();
  try {
    await context.addInitScript({content: script});
    const page = await context.newPage();
    await page.route('**/*', route => route.fulfill({contentType: 'text/html', body:
      new URL(route.request().url()).hostname === 'www.youtube.com' ? playerHtml :
        '<!doctype html><html><body><iframe src="https://www.youtube.com/embed/fixture?enablejsapi=1"></iframe></body></html>'
    }));
    await page.goto('https://trexsatya.github.io/language.html');
    const frame = page.frames().find(f => f.url().startsWith('https://www.youtube.com/embed/'));
    await page.evaluate(() => window.CupitorYouTubeControls.setVisible(false));
    await frame.waitForFunction(() => document.documentElement.classList.contains('cupitor-youtube-controls-hidden'));
    await run(page, frame);
  } finally { await context.close(); }
}

async function opacity(frame, selector) {
  return frame.locator(selector).evaluate(e => getComputedStyle(e).opacity);
}

test('pause/resume style rewrites stay hidden even with inline !important and transitions', async () => {
  await fixture(async (page, frame) => {
    for (const state of ['paused-mode', 'playing-mode', 'unstarted-mode']) {
      await frame.evaluate(state => {
        document.body.className = state;
        for (const e of document.querySelectorAll('#top,#bottom,#pause')) {
          e.style.setProperty('opacity', '1', 'important');
          e.style.setProperty('visibility', 'visible', 'important');
          e.style.setProperty('transition', 'opacity 1s', 'important');
        }
      }, state);
      for (const selector of ['#top', '#bottom', '#pause']) assert.equal(await opacity(frame, selector), '0');
      assert.equal(await page.evaluate(() => window.CupitorYouTubeControls.visible), false);
    }
  });
});

test('new video controls, playback feedback and a cleared stylesheet remain hidden', async () => {
  await fixture(async (_, frame) => {
    await frame.evaluate(() => {
      document.getElementById('bottom').outerHTML = '<div id="bottom" class="ytp-chrome-bottom" style="opacity:1!important">New controls</div>';
      document.body.insertAdjacentHTML('beforeend', '<div id="bezel" class="ytp-bezel" style="visibility:visible!important">Play feedback</div>');
      document.getElementById('cupitor-youtube-controls-style').textContent = '';
      document.documentElement.className = '';
    });
    for (const selector of ['#top', '#bottom', '#bezel']) assert.equal(await opacity(frame, selector), '0');
  });
});

test('iframe document navigation inherits hidden state without another API call', async () => {
  await fixture(async (page) => {
    const navigated = page.waitForEvent('framenavigated', {
      predicate: f => f.url().includes('/embed/next')
    });
    await page.locator('iframe').evaluate(e => { e.src = 'https://www.youtube.com/embed/next?enablejsapi=1'; });
    const frame = await navigated;
    await frame.waitForFunction(() => document.documentElement.classList.contains('cupitor-youtube-controls-hidden'));
    assert.equal(await opacity(frame, '#top'), '0');
  });
});

test('explicit show still works and restores the latest non-bar player styles', async () => {
  await fixture(async (page, frame) => {
    await frame.locator('#pause').evaluate(e => { e.style.cssText = 'opacity:0.6!important;visibility:visible!important'; });
    assert.equal(await opacity(frame, '#pause'), '0');
    await page.evaluate(() => window.CupitorYouTubeControls.setVisible(true));
    await frame.waitForFunction(() => document.documentElement.classList.contains('cupitor-youtube-controls-shown'));
    assert.equal(await opacity(frame, '#top'), '1');
    assert.equal(await opacity(frame, '#bottom'), '1');
    assert.equal(await opacity(frame, '#pause'), '0.6');
    await page.evaluate(() => window.CupitorYouTubeControls.setVisible(false));
    await frame.waitForFunction(() => document.documentElement.classList.contains('cupitor-youtube-controls-hidden'));
    assert.equal(await opacity(frame, '#top'), '0');
  });
});

test('video, captions, errors and loading indicators stay visible', async () => {
  await fixture(async (_, frame) => {
    for (const selector of ['#video', '#captions', '#error', '#spinner']) {
      assert.equal(await opacity(frame, selector), '1');
      assert.equal(await frame.locator(selector).evaluate(e => getComputedStyle(e).visibility), 'visible');
    }
  });
});

test('the mutation observer settles without a style write loop', async () => {
  await fixture(async (_, frame) => {
    const count = await frame.evaluate(async () => {
      let writes = 0;
      const observer = new MutationObserver(records => { writes += records.length; });
      observer.observe(document, {subtree: true, attributes: true});
      await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
      observer.disconnect();
      return writes;
    });
    assert.equal(count, 0);
  });
});
