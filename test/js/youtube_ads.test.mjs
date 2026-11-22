import {readFileSync} from 'node:fs';
import vm from 'node:vm';
import test from 'node:test';
import assert from 'node:assert/strict';

const script = readFileSync(process.env.CUPITOR_FRAME_BOOT_TEST_FILE || new URL('../../assets/js/frame_boot.js', import.meta.url), 'utf8');

function page(host = 'www.youtube.com', nativeStatus) {
  const frames = [], listeners = new Map(), observers = [], polls = [];
  let clock = 0;
  const context = vm.createContext({
    URL, WeakMap, WeakSet, location: new URL(`https://${host}/embed/content`),
    document: {querySelector: () => null, querySelectorAll: () => frames},
    MutationObserver: class { constructor(callback) { observers.push(callback); } observe() {} },
    setInterval: callback => { polls.push(callback); return polls.length; },
    Date: class extends Date { static now() { return clock; } },
    fetch: async () => new Response('{}'), Response,
    addEventListener: (event, callback) => listeners.set(event, callback),
  });
  context.window = context; context.top = context; context.parent = context;
  if (nativeStatus) context.CupitorBraveNative = {query:() => JSON.stringify(nativeStatus)};
  vm.runInContext(script, context);
  return {context, frames, listeners, mutate: () => observers.forEach(callback => callback()),
    poll: (elapsed = 500) => { clock += elapsed; polls.forEach(callback => callback()); },
    run: code => vm.runInContext(code, context)};
}

const response = `({adPlacements:[1], playerAds:[2], adSlots:[3],
  videoDetails:{videoId:'content'}, streamingData:{formats:[{url:'media'}]},
  captions:{playerCaptionsTracklistRenderer:{captionTracks:[]}}})`;
const clean = value => JSON.parse(JSON.stringify(value));
const expected = {videoDetails:{videoId:'content'}, streamingData:{formats:[{url:'media'}]},
  captions:{playerCaptionsTracklistRenderer:{captionTracks:[]}}};

test('first embed config is pruned before its first read, including serialized player responses', () => {
  const p = page();
  p.run(`window.ytplayer = {}; window.ytplayer.config = {args:{
    raw_player_response: ${response}, player_response: JSON.stringify(${response})}};
    window.firstRead = window.ytplayer.config.args;`);
  assert.deepEqual(clean(p.context.firstRead.raw_player_response), expected);
  assert.deepEqual(JSON.parse(p.context.firstRead.player_response), expected);
});

test('ytcfg assigned before its set method still prunes embed configs and preserves method behavior', () => {
  const p = page();
  p.run(`window.ytcfg = {};
    window.ytcfg.set = function (value, extra) { this.data_ = value; return extra; };
    window.result = window.ytcfg.set({PLAYER_CONFIG:{args:{raw_player_response:${response}}}}, 42);`);
  assert.equal(p.context.result, 42);
  assert.deepEqual(clean(p.context.ytcfg.data_.PLAYER_CONFIG.args.raw_player_response), expected);
  p.run(`window.ytcfg.data_ = {PLAYER_CONFIG:{args:{raw_player_response:${response}}}};`);
  assert.deepEqual(clean(p.context.ytcfg.data_.PLAYER_CONFIG.args.raw_player_response), expected);
});

test('privacy-enhanced embeds are pruned too, without stripping unrelated nested data', () => {
  const p = page('www.youtube-nocookie.com');
  p.run(`window.ytInitialPlayerResponse = ${response};
    window.ytplayer = {config:{args:{raw_player_response:${response}}, unrelated:{adSlots:[9]}}};`);
  assert.deepEqual(clean(p.context.ytInitialPlayerResponse), expected);
  assert.deepEqual(clean(p.context.ytplayer.config.args.raw_player_response), expected);
  assert.deepEqual(clean(p.context.ytplayer.config.unrelated), {adSlots:[9]});
});

test('invalid serialized responses and non-configurable page properties remain usable', () => {
  const p = page();
  p.run(`window.ytplayer = {config:{args:{player_response:'invalid json'}}};`);
  assert.equal(p.context.ytplayer.config.args.player_response, 'invalid json');
  p.run(`Object.defineProperty(window, 'ytcfg', {value:{set:function(){return 7}}, configurable:false});`);
  assert.equal(p.context.ytcfg.set(), 7);
});

test('ad-state messages are isolated to the current iframe and verified YouTube origin', () => {
  const p = page('study.example');
  const source = {}, other = {};
  const frame = {src:'https://www.youtube.com/embed/content', contentWindow:source, isConnected:true};
  p.frames.push(frame);
  const send = (origin, from, playing) => p.listeners.get('message')({
    origin, source:from, data:{type:'cupitor:youtube-ad-state', playing},
  });
  send('https://www.youtube.com', source, true);
  assert.equal(p.context.CupitorYouTubeAds.isPlaying(frame), true);
  for (const [origin, from, playing] of [
    ['https://youtube.com.evil.test', source, false],
    ['https://www.youtube.com', other, false],
    ['https://www.youtube.com', source, 'false'],
  ]) {
    send(origin, from, playing);
    assert.equal(p.context.CupitorYouTubeAds.isPlaying(frame), true);
  }
  frame.src = 'https://www.youtube-nocookie.com/embed/content';
  assert.equal(p.context.CupitorYouTubeAds.isPlaying(frame), false);
  send('https://www.youtube-nocookie.com', source, true);
  assert.equal(p.context.CupitorYouTubeAds.isPlaying(frame), true);
  frame.isConnected = false;
  assert.equal(p.context.CupitorYouTubeAds.isPlaying(frame), false);
});

test('lookalike hosts do not receive config hooks or ad fallback', () => {
  const p = page('youtube.com.evil.test');
  p.run(`window.ytInitialPlayerResponse = ${response};`);
  assert.deepEqual(clean(p.context.ytInitialPlayerResponse.adSlots), [3]);
  assert.equal(p.context._ytAdFallbackInstalled, undefined);
});

test('Brave manages JSON hooks while the ad-state and Skip fallback remain installed', () => {
  const p = page('www.youtube.com', {ready:true, managed:true});
  p.run(`window.ytInitialPlayerResponse = ${response};`);
  assert.deepEqual(clean(p.context.ytInitialPlayerResponse.adSlots), [3], 'no second JSON-pruning layer');
  assert.equal(p.context._ytAdFallbackInstalled, 1);
});

test('native network support without document-start scriptlets keeps the JSON fallback', () => {
  const p = page('www.youtube.com', {ready:true, managed:false});
  p.run(`window.ytInitialPlayerResponse = ${response};`);
  assert.deepEqual(clean(p.context.ytInitialPlayerResponse), expected);
});

test('fallback waits for an enabled, visible Skip and does not repeatedly click the same button', () => {
  const p = page(), messages = [];
  const classes = new Set(['ad-showing']);
  let clicks = 0;
  const button = {disabled:true, visible:true, getAttribute:()=>null,
    getClientRects:()=>button.visible ? [{}] : [], click:()=>clicks++};
  const player = {classList:{contains:name=>classes.has(name)}, querySelectorAll:()=>[button]};
  p.context.document.querySelector = () => player;
  p.context.getComputedStyle = () => ({visibility:'visible'});
  p.context.parent = {postMessage:message=>messages.push(message)};
  p.mutate();
  assert.equal(clicks, 0);
  assert.equal(messages.at(-1).playing, true);
  button.disabled = false;
  button.visible = false;
  p.mutate();
  assert.equal(clicks, 0, 'hidden countdown buttons are not clickable');
  button.visible = true;
  p.mutate(); p.mutate();
  assert.equal(clicks, 1);
  button.disabled = true;
  p.mutate();
  button.disabled = false;
  p.mutate();
  assert.equal(clicks, 2, 'a reused countdown can become skippable again');
  classes.clear();
  p.mutate();
  assert.equal(messages.at(-1).playing, false);
});

test('an ignored Skip click is retried by polling and stops as soon as the ad ends', () => {
  const p = page();
  let ad = true, clicks = 0;
  const button = {disabled:false, getAttribute:()=>null, getClientRects:()=>[{}], click:()=>clicks++};
  p.context.document.querySelector = () => ({
    classList:{contains:()=>ad}, querySelectorAll:()=>[button],
  });
  p.context.getComputedStyle = () => ({visibility:'visible'});
  p.mutate();
  assert.equal(clicks, 1);
  p.poll();
  assert.equal(clicks, 1, 'retry is rate limited');
  p.poll();
  assert.equal(clicks, 2, 'same button is retried without a DOM mutation');
  ad = false;
  p.poll(2000);
  assert.equal(clicks, 2);
});

test('hiding Cupitor controls does not disable an enabled Skip button', () => {
  const p = page();
  let clicks = 0;
  const button = {disabled:false, getAttribute:()=>null, getClientRects:()=>[{}], click:()=>clicks++};
  p.context.document.querySelector = () => ({classList:{contains:()=>true}, querySelectorAll:()=>[button]});
  p.context.document.documentElement = {
    classList:{contains:name=>name === 'cupitor-youtube-controls-hidden'},
  };
  p.context.getComputedStyle = () => ({visibility:'hidden'});
  p.mutate();
  assert.equal(clicks, 1);
});
