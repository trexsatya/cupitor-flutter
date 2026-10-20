import assert from 'node:assert/strict';
import fs from 'node:fs';
import {createRequire} from 'node:module';
import {spawn} from 'node:child_process';
import {createInterface} from 'node:readline';
import {fileURLToPath, pathToFileURL} from 'node:url';
import test from 'node:test';
const require = createRequire(import.meta.url);
const {JSDOM} = require(process.env.CUPITOR_JSDOM || 'jsdom');
const id = '317TI86OHwkAxLtwi1VnXN', url = 'https://open.spotify.com/episode/' + id;
const script = fs.readFileSync(new URL('../../assets/js/spotify_clip.js', import.meta.url), 'utf8');

export function spotifyPage({session = false} = {}) {
  const dom = new JSDOM('<!doctype html><html><body></body></html>', {url, runScripts: 'outside-only'});
  const {window: win} = dom;
  win.console = {log() {}, warn() {}, error() {}};
  let clock = 10000, serial = 0;
  const timers = new Map(), starts = [];
  win.Date.now = () => clock;
  win.setInterval = fn => {timers.set(++serial, fn); return serial;};
  win.clearInterval = key => timers.delete(key);
  const proto = win.HTMLMediaElement.prototype;
  Object.defineProperties(proto, {
    duration: {configurable: true, get() {return 3307.76;}},
    readyState: {configurable: true, get() {return 4;}},
    paused: {configurable: true, get() {return this._paused !== false;}},
  });
  proto.play = function () {starts.push({media: this, position: this.currentTime, muted: this.muted}); this._paused = false; return Promise.resolve();};
  proto.pause = function () {this._paused = true;}; proto.load = function () {};
  let ms;
  if (session) {
    let value = 'paused';
    ms = {setPositionState() {}, setActionHandler() {}};
    Object.defineProperty(ms, 'playbackState', {configurable: true, get: () => value, set: next => {value = next;}});
    Object.defineProperty(win.navigator, 'mediaSession', {configurable: true, value: ms});
  }
  win.eval(script);
  const command = packet => win.__cupSpotifyClipAgent.command(packet);
  const cue = (sessionId = 'one', start = 12.52, end = 14.16) => command({op: 'cue', sessionId, url, start, end});
  const tick = (elapsed = 100) => {clock += elapsed; for (const fn of [...timers.values()]) fn();};
  return {win, ms, command, cue, tick, starts, close: () => win.close()};
}

test('the Spotify WebView pauses detached Audio at the end without another study-page poll', async () => {
  const f = spotifyPage();
  try {
    const audio = new f.win.Audio(); audio.currentTime = 200; await audio.play();
    f.win.__cupLookupHeld = [audio]; audio.__cupLookupHeld = true;
    f.cue(); f.tick();
    assert.equal(audio.currentTime, 12.52); assert.equal(audio.paused, true);
    assert.deepEqual([...f.win.__cupLookupHeld], []);
    f.command({op: 'play', sessionId: 'one'}); f.tick(); assert.equal(audio.paused, false);
    audio.currentTime = 14.16; f.tick();
    assert.equal(audio.paused, true, 'the local guard stops playback while dialog1 is covered');
    await audio.play(); f.tick(); assert.equal(audio.paused, true, 'a completed clip stays stopped');
  } finally {f.close();}
});

test('paused time does not finish a clip or trigger an automatic resume', async () => {
  const f = spotifyPage();
  try {
    const audio = new f.win.Audio(); await audio.play(); f.cue(); f.tick();
    f.command({op: 'play', sessionId: 'one'}); audio.currentTime = 13; f.tick();
    audio.pause(); f.tick(15000);
    assert.equal(f.command({op: 'state', sessionId: 'one'}).complete, false); assert.equal(audio.paused, true);
    f.command({op: 'play', sessionId: 'one'}); audio.currentTime = 14.16; f.tick();
    assert.equal(f.command({op: 'state', sessionId: 'one'}).complete, true); assert.equal(audio.paused, true);
  } finally {f.close();}
});

test('selecting a different episode stays muted until its real clock reaches the clip start', () => {
  const f = spotifyPage();
  try {
    f.win.document.body.innerHTML = '<main><button data-testid="play-button" aria-label="Play episode">Play</button></main>' +
      '<div data-testid="now-playing-widget"><a href="/episode/7makk4oTQel546B0PZlDM5">Other episode</a></div>';
    let audio;
    f.win.document.querySelector('button').onclick = () => {
      audio = new f.win.Audio(); audio.currentTime = 0; audio.play();
      f.win.document.querySelector('a').href = url;
    };
    f.cue();
    assert.ok(audio, 'the requested episode is activated');
    assert.equal(f.starts[0].position, 0); assert.equal(f.starts[0].muted, true, 'initial playback is inaudible');
    f.tick(); f.tick();
    assert.equal(audio.currentTime, 12.52); assert.equal(audio.paused, true); assert.equal(audio.muted, false, 'mute is released only after the confirmed paused seek');
    f.command({op: 'play', sessionId: 'one'}); f.tick();
    assert.equal(audio.muted, false); assert.equal(audio.paused, false);
    assert.equal(f.starts.at(-1).position, 12.52);
    audio.currentTime = 14.16; f.tick(); assert.equal(audio.paused, true);
  } finally {f.close();}
});

test('cancelling an episode activation pauses and unmutes its backing media', () => {
  const f = spotifyPage();
  try {
    f.win.document.body.innerHTML = '<main><button data-testid="play-button">Play</button></main>';
    let audio;
    f.win.document.querySelector('button').onclick = () => {audio = new f.win.Audio(); audio.play();};
    f.cue(); assert.equal(audio.muted, true);
    f.command({op: 'stop', sessionId: 'one'});
    assert.equal(audio.paused, true); assert.equal(audio.muted, false);
  } finally {f.close();}
});

test('old stop, play and seek commands cannot control the next passage', async () => {
  const f = spotifyPage();
  try {
    const audio = new f.win.Audio(); await audio.play(); f.cue(); f.tick();
    f.cue('two', 30, 32); f.tick();
    f.command({op: 'play', sessionId: 'two'});
    for (const op of ['stop', 'pause', 'seek']) f.command({op, sessionId: 'one', time: 12.52});
    assert.equal(audio.paused, false); assert.equal(audio.currentTime, 30);
    audio.currentTime = 32; f.tick(); assert.equal(audio.paused, true);
  } finally {f.close();}
});

test('MediaSession seeking must be observed before play, bypassing optimistic sidebar timestamps', () => {
  const f = spotifyPage({session: true}), seeks = [], plays = [];
  try {
    f.ms.setActionHandler('seekto', value => seeks.push(value.seekTime));
    f.ms.setActionHandler('play', () => {plays.push(true); f.ms.playbackState = 'playing';});
    f.ms.setActionHandler('pause', () => {f.ms.playbackState = 'paused';});
    f.ms.setPositionState({duration: 3307.76, position: 2});
    f.cue(); f.command({op: 'play', sessionId: 'one'}); f.tick();
    assert.equal(f.command({op: 'state', sessionId: 'one'}).ready, false);
    assert.deepEqual(seeks, [12.52]); assert.deepEqual(plays, []);
    f.ms.setPositionState({duration: 3307.76, position: 12.52}); f.tick();
    assert.equal(plays.length, 1);
    f.ms.setPositionState({duration: 3307.76, position: 14.16}); f.tick();
    assert.equal(f.ms.playbackState, 'paused');
  } finally {f.close();}
});

test('an unreachable timestamp fails and leaves Spotify paused', () => {
  const f = spotifyPage({session: true});
  try {
    f.ms.setActionHandler('seekto', () => {});
    f.ms.setActionHandler('pause', () => {f.ms.playbackState = 'paused';});
    f.ms.setPositionState({duration: 3307.76, position: 2});
    f.cue(); f.tick(21000);
    assert.match(f.command({op: 'state', sessionId: 'one'}).error, /timestamp/);
    assert.equal(f.ms.playbackState, 'paused');
  } finally {f.close();}
});

test('background time cannot expire a pending seek or resume audio', () => {
  const f = spotifyPage({session: true});
  try {
    f.ms.setActionHandler('seekto', () => {});
    f.ms.setActionHandler('pause', () => {f.ms.playbackState = 'paused';});
    f.ms.setPositionState({duration: 3307.76, position: 2});
    f.cue(); f.command({op: 'visibility', sessionId: 'one', foreground: false}); f.tick(60000);
    assert.equal(f.command({op: 'state', sessionId: 'one'}).error, null);
    f.command({op: 'visibility', sessionId: 'one', foreground: true});
    f.ms.setPositionState({duration: 3307.76, position: 12.52}); f.tick();
    assert.equal(f.command({op: 'state', sessionId: 'one'}).ready, true);
    assert.equal(f.ms.playbackState, 'paused');
  } finally {f.close();}
});

test('a different playing episode is never accepted as the requested clip', async () => {
  const f = spotifyPage();
  try {
    f.win.document.body.innerHTML = '<div data-testid="now-playing-widget"><a href="/episode/7makk4oTQel546B0PZlDM5">Other episode</a></div>';
    const audio = new f.win.Audio(); audio.currentTime = 12.52; await audio.play();
    f.cue(); f.command({op: 'play', sessionId: 'one'}); f.tick(21000);
    const state = f.command({op: 'state', sessionId: 'one'});
    assert.equal(state.ready, false); assert.match(state.error, /requested episode/); assert.equal(audio.paused, true);
  } finally {f.close();}
});

test('the packaged agent is inert on other sites and repeated injection keeps one guard', async () => {
  const f = spotifyPage();
  try {
    const agent = f.win.__cupSpotifyClipAgent; f.win.eval(script); assert.equal(f.win.__cupSpotifyClipAgent, agent);
    f.win.history.replaceState({}, '', '/');
  } finally {f.close();}
  const dom = new JSDOM('', {url: 'https://trexsatya.github.io', runScripts: 'outside-only'});
  try {dom.window.eval(script); assert.equal(dom.window.__cupSpotifyClipAgent, undefined);} finally {dom.window.close();}
});

test('the real Dart bridge connects the study page to Spotify and advances between bounded passages', {
  skip: !process.env.CUPITOR_DART || !process.env.CUPITOR_WEB_ROOT, timeout: 15000,
}, async () => {
  const f = spotifyPage();
  const study = new JSDOM('<!doctype html><html><body><div id="mediaContainer"></div></body></html>', {runScripts: 'outside-only'});
  const child = spawn(process.env.CUPITOR_DART, [fileURLToPath(new URL('../../tool/spotify_clip_fixture.dart', import.meta.url))]);
  const pending = new Map(), writes = []; let serial = 0;
  const write = value => child.stdin.write(JSON.stringify(value) + '\n');
  const call = (kind, packet) => {
    const id = ++serial;
    const promise = new Promise((resolve, reject) => pending.set(id, {resolve, reject}));
    write({kind, id, packet}); return promise;
  };
  const lines = createInterface({input: child.stdout});
  lines.on('line', line => {
    const message = JSON.parse(line);
    if (message.kind === 'evaluate') write({kind: 'result', id: message.id, value: f.win.eval(message.script)});
    if (message.kind === 'event') study.window.dispatchEvent(new study.window.CustomEvent('cupitorSpotifyClip', {detail: message.detail}));
    if (message.kind === 'done') {
      const result = pending.get(message.id); pending.delete(message.id);
      if (message.error) result?.reject(new Error(message.error)); else result?.resolve();
    }
  });
  child.on('exit', code => {for (const value of pending.values()) value.reject(new Error('Dart bridge exited: ' + code));});
  study.window.SpotifyClipBridge = {postMessage: value => writes.push(call('handle', JSON.parse(value)))};
  const flush = async () => {
    for (let i = 0; i < 5; i++) {
      for (let j = 0; j < 8; j++) await Promise.resolve();
      await Promise.all(writes.splice(0));
    }
  };
  let player;
  try {
    const {createSpotifyStudyPlayer} = await import(pathToFileURL(process.env.CUPITOR_WEB_ROOT + '/language/spotify-player.js'));
    const audio = new f.win.Audio(); audio.currentTime = 200; await audio.play();
    player = createSpotifyStudyPlayer({win: study.window, isForeground: () => true});
    const done = player.playCard({manual: true, mediaUrl: url, captionUrl: url, captionStarts: [12.52, 30], captionEnds: [14.16, 32]});
    await flush(); f.tick(); await call('poll'); await flush();
    assert.equal(audio.currentTime, 12.52); assert.equal(audio.paused, false);
    assert.equal(study.window.document.querySelector('iframe'), null);
    audio.currentTime = 14.16; f.tick();
    assert.equal(audio.paused, true, 'the Spotify WebView stops before the study page gets its next event');
    await call('poll'); await flush(); f.tick(); await call('poll'); await flush();
    assert.equal(audio.currentTime, 30); assert.equal(audio.paused, false, 'the next selected passage starts automatically');
    audio.currentTime = 32; f.tick(); assert.equal(audio.paused, true);
    await call('poll'); await flush(); assert.equal(await done, true);
    player.stop(); await flush();
  } finally {player?.stop(); child.kill(); lines.close(); study.window.close(); f.close();}
});
