const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {test, before, after} = require('node:test');
const {chromium} = require('playwright-core');
const script = fs.readFileSync(path.join(__dirname, '../../assets/js/frame_boot.js'), 'utf8');
const controls = fs.readFileSync(path.join(__dirname, '../../assets/js/youtube_controls.js'), 'utf8');
let browser;
before(async () => { browser = await chromium.launch({
  executablePath: process.env.CUPITOR_CHROME_PATH, headless: true, args: ['--no-sandbox'],
}); });
after(async () => { await browser?.close(); });

async function fixture(run, host = 'www.youtube.com') {
  const context = await browser.newContext();
  try {
    await context.addInitScript({content: script + '\n' + controls});
    const page = await context.newPage();
    await page.route('**/*', route => route.fulfill({contentType: 'text/html', body:
      new URL(route.request().url()).pathname.startsWith('/embed/') ? `<!doctype html>
        <script>
          window.ytInitialPlayerResponse = {adPlacements:[1], playerAds:[2], videoDetails:{videoId:'content'}};
          window.skipClicks = 0;
        </script>
        <div class="html5-video-player ad-showing">
          <video></video><div class="ytp-chrome-bottom"><button class="ytp-skip-ad-button" disabled>Skip ad</button></div>
        </div>` : `<!doctype html><iframe id="player" src="https://${host}/embed/content"></iframe>`
    }));
    await page.goto('https://study.example/language.html');
    const frame = page.frames().find(f => f.url().includes('/embed/'));
    await page.waitForFunction(() => window.CupitorYouTubeAds.isPlaying(document.querySelector('iframe')));
    await frame.evaluate(() => {
      document.querySelector('button').onclick = () => {
        window.skipClicks++;
        document.querySelector('.html5-video-player').classList.remove('ad-showing');
      };
    });
    await run(page, frame);
  } finally { await context.close(); }
}

test('embedded fallback clicks Skip once when its countdown ends and reports content resuming', async () => {
  await fixture(async (page, frame) => {
    assert.equal(await frame.evaluate(() => window.skipClicks), 0);
    assert.equal(await frame.locator('button').isVisible(), true, 'manual Skip stays usable');
    await frame.locator('button').evaluate(button => { button.disabled = false; });
    await page.waitForFunction(() => !window.CupitorYouTubeAds.isPlaying(document.querySelector('iframe')));
    assert.equal(await frame.evaluate(() => window.skipClicks), 1);
    assert.equal(frame.url(), 'https://www.youtube.com/embed/content');
  });
});

test('an ad with no usable Skip remains intact, without seek or reload commands', async () => {
  await fixture(async (page, frame) => {
    await frame.evaluate(() => { document.querySelector('button').remove(); });
    assert.equal(await page.evaluate(() => window.CupitorYouTubeAds.isPlaying(document.querySelector('iframe'))), true);
    assert.equal(await frame.evaluate(() => document.querySelector('video').currentTime), 0);
    assert.equal(await frame.evaluate(() => document.querySelector('video').playbackRate), 1);
    await frame.evaluate(() => {
      const player = document.querySelector('.html5-video-player');
      player.classList.replace('ad-showing', 'ad-interrupting');
      player.insertAdjacentHTML('beforeend', '<div><button class="ytp-ad-skip-button-modern">Skip</button></div>');
      player.querySelector('button').onclick = () => { window.skipClicks++; player.classList.remove('ad-interrupting'); };
    });
    await page.waitForFunction(() => !window.CupitorYouTubeAds.isPlaying(document.querySelector('iframe')));
    assert.equal(await frame.evaluate(() => window.skipClicks), 1);
  });
});

test('privacy-enhanced embeds receive pruning, fallback and ad-state reporting', async () => {
  await fixture(async (page, frame) => {
    assert.deepEqual(await frame.evaluate(() => window.ytInitialPlayerResponse), {videoDetails: {videoId: 'content'}});
    await frame.locator('button').evaluate(button => { button.disabled = false; });
    await page.waitForFunction(() => !window.CupitorYouTubeAds.isPlaying(document.querySelector('iframe')));
  }, 'www.youtube-nocookie.com');
});

test('state from the parent or a detached player cannot impersonate the current embed', async () => {
  await fixture(async (page, frame) => {
    await page.evaluate(() => window.postMessage({type: 'cupitor:youtube-ad-state', playing: false}, '*'));
    assert.equal(await page.evaluate(() => window.CupitorYouTubeAds.isPlaying(document.querySelector('iframe'))), true);
    await frame.evaluate(() => { window.parent.postMessage({type: 'cupitor:youtube-ad-state', playing: 'false'}, '*'); });
    assert.equal(await page.evaluate(() => window.CupitorYouTubeAds.isPlaying(document.querySelector('iframe'))), true);
    assert.equal(await page.evaluate(() => {
      const iframe = document.querySelector('iframe');
      iframe.remove();
      return window.CupitorYouTubeAds.isPlaying(iframe);
    }), false);
  });
});

test('replacing the player updates the ad state without reinjecting the script', async () => {
  await fixture(async (page, frame) => {
    await frame.evaluate(() => { document.querySelector('.html5-video-player').outerHTML = '<div class="html5-video-player"><video></video></div>'; });
    await page.waitForFunction(() => !window.CupitorYouTubeAds.isPlaying(document.querySelector('iframe')));
    await frame.evaluate(() => { document.querySelector('.html5-video-player').classList.add('ad-showing'); });
    await page.waitForFunction(() => window.CupitorYouTubeAds.isPlaying(document.querySelector('iframe')));
  });
});

test('an ignored click is retried without a button replacement or DOM mutation', async () => {
  await fixture(async (page, frame) => {
    await frame.evaluate(() => {
      const button = document.querySelector('button');
      button.onclick = () => {
        if (++window.skipClicks >= 2) document.querySelector('.html5-video-player').classList.remove('ad-showing');
      };
      button.disabled = false;
    });
    await page.waitForFunction(() => !window.CupitorYouTubeAds.isPlaying(document.querySelector('iframe')));
    assert.equal(await frame.evaluate(() => window.skipClicks), 2);
  });
});

test('Cupitor control hiding cannot suppress auto-skip inside a cross-origin iframe', async () => {
  await fixture(async (page, frame) => {
    await page.evaluate(() => window.CupitorYouTubeControls?.setVisible(false));
    await frame.evaluate(() => {
      if (!window.__cupitorYouTubeControlsInstalled) document.documentElement.classList.add('cupitor-youtube-controls-hidden');
      document.querySelector('button').parentElement.style.visibility = 'hidden';
      document.querySelector('button').disabled = false;
    });
    await page.waitForFunction(() => !window.CupitorYouTubeAds.isPlaying(document.querySelector('iframe')));
    assert.equal(await frame.evaluate(() => window.skipClicks), 1);
  });
});
