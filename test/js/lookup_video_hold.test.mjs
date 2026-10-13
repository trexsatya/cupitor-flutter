// Pausing the page's videos while the lookup dialog is open, and playing them
// again when it closes (lib/lookup_video_hold.dart), together with the caption
// sidebar that also pauses and plays the video (snippet.js, sibling repo
// trexsatya.github.io, src/20-caption-sidebar.js).
//
// Runs the real scripts: the hold/release JS is read out of the Dart file, the
// sidebar from its source. jsdom comes from $CUPITOR_JSDOM or the frontend
// checkout beside this one.
//
//   node test/js/lookup_video_hold.test.mjs
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '../..');
const PROJECTS = path.resolve(ROOT, '../..');
const SIDEBAR_SRC = process.env.CUPITOR_SIDEBAR_SRC ||
  path.join(PROJECTS, 'trexsatya.github.io/db/js/src/20-caption-sidebar.js');

function loadJsdom() {
  const candidates = [
    process.env.CUPITOR_JSDOM,
    'jsdom',
    path.join(PROJECTS, 'cupitor/frontend/vue3/cupitor-frontend/node_modules/jsdom'),
  ].filter(Boolean);
  for (const c of candidates) {
    try { return require(c); } catch (_) { /* next */ }
  }
  console.error('jsdom not found. Point CUPITOR_JSDOM at a jsdom package directory.');
  process.exit(2);
}
const { JSDOM } = loadJsdom();

// The Dart constants, with `$_videosJs` filled in as Dart would.
const dart = fs.readFileSync(path.join(ROOT, 'lib/lookup_video_hold.dart'), 'utf8');
function dartConst(name) {
  const m = dart.match(new RegExp(`const String ${name} = '''([\\s\\S]*?)''';`));
  if (!m) throw new Error(`${name} not found in lookup_video_hold.dart`);
  return m[1];
}
const VIDEOS = dartConst('_videosJs');
const HOLD = dartConst('kHoldVideosForLookupJs').replace('$_videosJs', VIDEOS);
const RELEASE = dartConst('kReleaseVideosAfterLookupJs');
assert.ok(!HOLD.includes('$') && !RELEASE.includes('$'), 'unfilled Dart interpolation');

function boot(bodyHtml = '', { prefs } = {}) {
  const dom = new JSDOM(`<!DOCTYPE html><html><body>${bodyHtml}</body></html>`, {
    runScripts: 'outside-only', pretendToBeVisual: true, url: 'https://example.test/watch',
  });
  const { window } = dom;
  // jsdom has no media playback; this behaves like a browser's for the parts
  // used here: `paused` flips synchronously, the event follows as a task.
  const P = window.HTMLMediaElement.prototype;
  Object.defineProperty(P, 'paused', { configurable: true, get() { return this._paused !== false; } });
  Object.defineProperty(P, 'ended', { configurable: true, get() { return false; } });
  P.pause = function () {
    if (this.paused) return;
    this._paused = true;
    setTimeout(() => this.dispatchEvent(new window.Event('pause')));
  };
  P.play = function () {
    if (!this.paused) return Promise.resolve();
    this._paused = false;
    setTimeout(() => this.dispatchEvent(new window.Event('play')));
    return Promise.resolve();
  };
  const logs = [];
  window.console = { log: (...a) => logs.push(a.join(' ')), warn() {}, error() {}, info() {} };
  const translateRequests = [];
  window.TranslateRequest = { postMessage: (m) => translateRequests.push(JSON.parse(m)) };
  if (prefs) window.localStorage.setItem('cupSubPrefs', JSON.stringify(prefs));
  return { window, document: window.document, logs, translateRequests };
}
const tick = () => new Promise((r) => setTimeout(r, 5));
const video = (doc, id) => doc.getElementById(id);

const tests = [];
const test = (name, fn) => tests.push({ name, fn });

// ── hold / release on their own ────────────────────────────────────────────

test('given a playing video, when held, then it pauses; when released, it plays again', async () => {
  const { window, document } = boot('<video id="a"></video>');
  const a = video(document, 'a');
  a.play(); await tick();
  window.eval(HOLD); await tick();
  assert.equal(a.paused, true);
  assert.equal(window.__cupLookupHold, true);
  window.eval(RELEASE); await tick();
  assert.equal(a.paused, false);
  assert.equal(window.__cupLookupHold, false);
});

test('given a video the user paused, when held and released, then it stays paused', async () => {
  const { window, document } = boot('<video id="a"></video><video id="b"></video>');
  const a = video(document, 'a'), b = video(document, 'b');
  a.play(); await tick(); // b never started
  window.eval(HOLD); await tick();
  window.eval(RELEASE); await tick();
  assert.equal(a.paused, false);
  assert.equal(b.paused, true);
});

test('given nothing held, when released, then nothing starts', async () => {
  const { window, document } = boot('<video id="a"></video>');
  window.eval(RELEASE); await tick();
  assert.equal(video(document, 'a').paused, true);
});

test('given a released hold, when released again, then a since-paused video stays paused', async () => {
  const { window, document } = boot('<video id="a"></video>');
  const a = video(document, 'a');
  a.play(); await tick();
  window.eval(HOLD); await tick();
  window.eval(RELEASE); await tick();
  a.pause(); await tick();
  window.eval(RELEASE); await tick();
  assert.equal(a.paused, true);
});

test('given a held video removed from the page, when released, then it is not played', async () => {
  const { window, document } = boot('<video id="a"></video>');
  const a = video(document, 'a');
  a.play(); await tick();
  window.eval(HOLD); await tick();
  a.remove();
  window.eval(RELEASE); await tick();
  assert.equal(a.paused, true);
});

test('given a held video the page played meanwhile, when released, then it is left alone', async () => {
  const { window, document } = boot('<video id="a"></video>');
  const a = video(document, 'a');
  a.play(); await tick();
  window.eval(HOLD); await tick();
  a.play(); await tick();
  let plays = 0;
  a.addEventListener('play', () => plays++);
  window.eval(RELEASE); await tick();
  assert.equal(plays, 0);
  assert.ok(!a.__cupLookupResuming, 'no stale resume mark');
});

test('given a video in a same-origin iframe, when held and released, then it pauses and resumes', async () => {
  const { window, document } = boot('<iframe></iframe>');
  const fdoc = document.querySelector('iframe').contentDocument;
  fdoc.body.innerHTML = '<video id="f"></video>';
  const f = fdoc.getElementById('f');
  f.play(); await tick();
  window.eval(HOLD); await tick();
  assert.equal(f.paused, true);
  window.eval(RELEASE); await tick();
  assert.equal(f.paused, false);
});

test('given a second hold before release, then videos started in between are held too', async () => {
  const { window, document } = boot('<video id="a"></video><video id="b"></video>');
  const a = video(document, 'a'), b = video(document, 'b');
  a.play(); await tick();
  window.eval(HOLD); await tick();
  b.play(); await tick();
  window.eval(HOLD); await tick();
  assert.equal(b.paused, true);
  window.eval(RELEASE); await tick();
  assert.equal(a.paused, false);
  assert.equal(b.paused, false);
});

// ── with the caption sidebar ───────────────────────────────────────────────

function bootSidebar(prefs) {
  const env = boot('<video id="v"></video>', { prefs: { debug: true, ...prefs } });
  env.window.eval(fs.readFileSync(SIDEBAR_SRC, 'utf8'));
  const ui = env.window.__cupShared.createSubtitleUI({});
  ui.buildSidebar && ui.buildSidebar();
  const v = video(env.document, 'v');
  ui.setVideoElement(v);
  return { ...env, ui, v };
}

test('given the sidebar, when the app holds and releases, then it is not taken as the user pausing', async () => {
  const { window, v, logs } = bootSidebar({});
  v.play(); await tick();
  window.eval(HOLD); await tick();
  window.eval(RELEASE); await tick();
  assert.ok(logs.some((l) => l.includes('pause: lookup hold')), logs.join('\n'));
  assert.ok(logs.some((l) => l.includes('play: lookup release')), logs.join('\n'));
  assert.ok(!logs.some((l) => l.includes('userOverrode=true')), logs.join('\n'));
  assert.ok(!logs.some((l) => l.includes('abandoning replay')), logs.join('\n'));
});

test('given the dialog closes before the hold\'s pause event arrives, then the sidebar still sees no user pause', async () => {
  const { window, v, logs } = bootSidebar({});
  v.play(); await tick();
  window.eval(HOLD);
  window.eval(RELEASE); // same task: the pause event has not been delivered yet
  await tick();
  assert.ok(!logs.some((l) => l.includes('userOverrode=true')), logs.join('\n'));
  assert.equal(v.paused, false);
});

test('given the user really pauses after a release, then the sidebar still sees it as the user', async () => {
  const { window, v, logs } = bootSidebar({});
  v.play(); await tick();
  window.eval(HOLD); await tick();
  window.eval(RELEASE); await tick();
  v.pause(); await tick();
  assert.ok(logs.some((l) => l.includes('userOverrode=true')), logs.join('\n'));
});

test('given "pause until translated" waiting, when the translation lands during a hold, then it plays only on release', async () => {
  const { window, ui, v, translateRequests } = bootSidebar({ translationEnabled: true, strategy: 2 });
  ui.addCue({ start: 0, end: 5, text: 'Hej på dig' });
  await tick();
  v.play(); await tick();
  v.currentTime = 1;
  v.dispatchEvent(new window.Event('timeupdate')); await tick();
  assert.equal(v.paused, true, 'strategy 2 pauses on the untranslated cue');
  // Word tap → the app holds. The video is already paused, so nothing is held.
  window.eval(HOLD); await tick();
  const req = translateRequests.at(-1);
  assert.ok(req, 'a translation was requested');
  window.__cupTranslated(req.id, 'Hi there');
  await tick();
  assert.equal(v.paused, true, 'must not play behind the dialog');
  window.eval(RELEASE); await tick();
  assert.equal(v.paused, false, 'plays once the dialog is gone');
});

let failed = 0;
for (const t of tests) {
  try { await t.fn(); console.log('PASS', t.name); }
  catch (e) { failed++; console.log('FAIL', t.name, '\n  ', e.message); }
}
console.log(`\n${tests.length - failed}/${tests.length} passed`);
process.exit(failed ? 1 : 0);
