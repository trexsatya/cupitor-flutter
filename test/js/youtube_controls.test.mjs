import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const script = readFileSync(new URL('../../assets/js/youtube_controls.js', import.meta.url), 'utf8');
const hiddenClass = 'cupitor-youtube-controls-hidden';
const shownClass = 'cupitor-youtube-controls-shown';

// Independent origins/windows with a queued postMessage transport. No DOM
// access across frames is provided: the bridge must exchange messages.
function browser() {
  let active;
  const messages = [];
  function enter(frame, callback) {
    const previous = active;
    active = frame;
    try { return callback(); } finally { active = previous; }
  }
  function frame(url, parent, beforeHtml = false) {
    const observers = [];
    const listeners = new Map();
    const iframes = [];
    const root = {
      classes: new Set(), children: [],
      classList: {
        contains: value => root.classes.has(value),
        toggle: (value, on) => on ? root.classes.add(value) : root.classes.delete(value),
      },
      appendChild(node) { node.isConnected = true; this.children.push(node); },
    };
    const document = {
      documentElement: beforeHtml ? null : root,
      querySelectorAll: selector => selector === 'iframe' ? iframes : [],
      createElement: tag => ({tagName: tag.toUpperCase(), isConnected: false}),
    };
    const location = new URL(url);
    const window = {
      addEventListener(name, fn) {
        if (!listeners.has(name)) listeners.set(name, []);
        listeners.get(name).push(fn);
      },
      dispatchEvent(event) {
        for (const fn of listeners.get(event.type) || []) enter(result, () => fn(event));
      },
      postMessage(data, targetOrigin) {
        if (targetOrigin !== '*' && targetOrigin !== location.origin) return;
        const source = active;
        messages.push(() => window.dispatchEvent({
          type: 'message', data, source: source.window, origin: source.location.origin,
        }));
      },
    };
    window.top = parent ? parent.window.top : window;
    window.parent = parent ? parent.window : window;
    const context = vm.createContext({
      window, document, location, URL,
      CustomEvent: class { constructor(type, options) { Object.assign(this, {type}, options); } },
      MutationObserver: class {
        constructor(callback) { observers.push(callback); }
        observe() {}
      },
    });
    const result = {window, document, location, root, iframes, listeners,
      run: code => enter(result, () => vm.runInContext(code, context)),
      inject: () => enter(result, () => vm.runInContext(script, context)),
      mutate: () => observers.forEach(callback => enter(result, callback)),
    };
    if (parent) parent.iframes.push({src: url, contentWindow: window});
    result.inject();
    return result;
  }
  function flush() {
    let remaining = 100;
    while (messages.length) {
      assert.ok(remaining-- > 0, 'message exchange must settle');
      messages.shift()();
    }
  }
  const top = frame('https://trexsatya.github.io/language.html');
  return {top, frame: (url, beforeHtml) => frame(url, top, beforeHtml), flush};
}

test('hide and restore controls in existing YouTube and privacy-enhanced embeds', () => {
  const b = browser();
  const yt = b.frame('https://www.youtube.com/embed/one?enablejsapi=1');
  const privacy = b.frame('https://www.youtube-nocookie.com/embed/two');
  b.flush();
  assert.equal(b.top.window.CupitorYouTubeControls.visible, true);
  assert.equal(yt.root.classes.has(hiddenClass), false);
  b.top.run('window.CupitorYouTubeControls.setVisible(false)');
  b.flush();
  for (const frame of [yt, privacy]) assert.equal(frame.root.classes.has(hiddenClass), true);
  b.top.run('window.CupitorYouTubeControls.setVisible(true)');
  b.flush();
  for (const frame of [yt, privacy]) assert.equal(frame.root.classes.has(hiddenClass), false);
});

test('new and replacement iframe documents inherit the current hidden state', () => {
  const b = browser();
  b.top.run('window.CupitorYouTubeControls.setVisible(false)');
  const old = b.frame('https://www.youtube.com/embed/one');
  b.flush();
  assert.equal(old.root.classes.has(hiddenClass), true);
  b.top.iframes.length = 0;
  const replacement = b.frame('https://youtube.com/embed/two');
  b.flush();
  assert.equal(replacement.root.classes.has(hiddenClass), true);
  b.top.run('window.CupitorYouTubeControls.setVisible(true)');
  b.flush();
  assert.equal(replacement.root.classes.has(hiddenClass), false);
});

test('iframe handshake observes the latest request when loading overlaps a toggle', () => {
  const b = browser();
  const yt = b.frame('https://www.youtube.com/embed/one');
  b.top.run('window.CupitorYouTubeControls.setVisible(false)');
  b.top.run('window.CupitorYouTubeControls.setVisible(true)');
  b.flush();
  assert.equal(yt.root.classes.has(hiddenClass), false);
});

test('document-start state applies once the HTML root exists; removed CSS is restored', () => {
  const b = browser();
  const yt = b.frame('https://m.youtube.com/embed/one', true);
  b.top.run('window.CupitorYouTubeControls.setVisible(false)');
  b.flush();
  yt.document.documentElement = yt.root;
  yt.mutate();
  assert.equal(yt.root.classes.has(hiddenClass), true);
  const style = yt.root.children[0];
  style.isConnected = false;
  yt.root.classes.clear();
  yt.mutate();
  assert.equal(style.isConnected, true);
  assert.equal(yt.root.classes.has(hiddenClass), true);
});

test('unrelated frames, watch pages and lookalike YouTube hosts are untouched', () => {
  const b = browser();
  const ignored = [
    'https://example.com/embed/one', 'https://www.youtube.com/watch?v=one',
    'https://youtube.com.evil.test/embed/one', 'http://www.youtube.com/embed/one',
    'https://www.youtube.com:8443/embed/one',
  ].map(url => b.frame(url));
  b.top.run('window.CupitorYouTubeControls.setVisible(false)');
  b.flush();
  for (const frame of ignored) {
    assert.equal(frame.root.children.length, 0);
    assert.equal(frame.window.CupitorYouTubeControls, undefined);
  }
});

test('an embed only accepts valid state messages from its own parent window', () => {
  const b = browser();
  const yt = b.frame('https://www.youtube.com/embed/one');
  const other = b.frame('https://example.com/');
  b.flush();
  yt.window.dispatchEvent({type: 'message', source: other.window,
    data: {type: 'cupitor:youtube-controls', visible: false}});
  yt.window.dispatchEvent({type: 'message', source: b.top.window,
    data: {type: 'cupitor:youtube-controls', visible: 'false'}});
  assert.equal(yt.root.classes.has(hiddenClass), false);
});

test('only current child windows from an allowed origin receive readiness replies', () => {
  const b = browser();
  const spoof = b.frame('https://youtube.com.evil.test/embed/one');
  const detached = b.frame('https://www.youtube.com/embed/one');
  b.top.iframes.pop();
  b.top.run('window.CupitorYouTubeControls.setVisible(false)');
  spoof.run("window.parent.postMessage({type: 'cupitor:youtube-controls-ready'}, '*')");
  b.flush();
  assert.equal(detached.root.classes.has(hiddenClass), false);
});

test('API validates booleans, reports requested state and is idempotent on reinjection', () => {
  const b = browser();
  const events = [];
  b.top.window.addEventListener('cupitorYouTubeControlsChanged', event => events.push(event.detail.visible));
  assert.throws(() => b.top.run('window.CupitorYouTubeControls.setVisible("false")'), /boolean/);
  b.top.run('window.CupitorYouTubeControls.setVisible(false)');
  const api = b.top.window.CupitorYouTubeControls;
  b.top.inject();
  assert.equal(b.top.window.CupitorYouTubeControls, api);
  assert.equal(api.visible, false);
  const yt = b.frame('https://www.youtube.com/embed/one');
  const count = yt.listeners.get('message').length;
  yt.inject();
  assert.equal(yt.listeners.get('message').length, count);
  b.flush();
  assert.deepEqual(events, [false]);
});


test('explicit show holds bars visible, and the bridge leaves all input handling to the webapp', () => {
  const b = browser();
  const yt = b.frame('https://www.youtube.com/embed/one');
  b.flush();
  assert.equal(yt.root.classes.has(shownClass), false, 'default preserves native auto-hide');
  for (let i = 0; i < 2; i++) {
    b.top.run('window.CupitorYouTubeControls.setVisible(false)');
    b.flush();
    assert.equal(yt.root.classes.has(shownClass), false);
    assert.equal(yt.root.classes.has(hiddenClass), true);
    b.top.run('window.CupitorYouTubeControls.setVisible(true)');
    b.flush();
    assert.equal(yt.root.classes.has(shownClass), true);
    assert.equal(yt.root.classes.has(hiddenClass), false);
  }
  for (const event of ['click', 'touchstart', 'touchend', 'pointerdown', 'pointerup']) {
    assert.equal(yt.listeners.has(event), false);
    assert.equal(b.top.listeners.has(event), false);
  }
});
