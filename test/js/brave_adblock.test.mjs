import {readFileSync} from 'node:fs';
import vm from 'node:vm';
import test from 'node:test';
import assert from 'node:assert/strict';

const source = readFileSync(new URL('../../assets/js/brave_adblock.js', import.meta.url), 'utf8');
function page({ready = true, enabled = true, transport = 'android', match = () => ({}), prelude = ''} = {}) {
  const queries = [], fetched = [], opened = [], observers = [];
  const root = {appendChild: node => { node.isConnected = true; }};
  const context = vm.createContext({URL, Response, Request, Uint8Array, atob,
    location:new URL('https://study.example/video'),
    document:{referrer:'', readyState:'complete', documentElement:root,
      createElement:() => ({sheet:{}, textContent:'', isConnected:false}), querySelectorAll:() => []},
    MutationObserver:class { constructor(callback) { observers.push(callback); } observe() {} },
    setTimeout:() => 1,
    fetch:async (...args) => { fetched.push(args); return new Response('allowed'); },
    XMLHttpRequest:class { open(...args) { opened.push(args); } },
  });
  context.window = context;
  const query = message => {
    const input = JSON.parse(message); queries.push(input);
    return JSON.stringify(input.op === 'status' ? {ready, enabled} : match(input));
  };
  if (transport === 'android') context.CupitorBraveNative = {query};
  else context.prompt = (name, message) => { assert.equal(name, '__cupitor_brave_v1__'); return query(message); };
  vm.runInContext(prelude, context);
  const original = context.fetch;
  vm.runInContext(source, context);
  return {context, queries, fetched, opened, original, run:code => vm.runInContext(code, context)};
}

test('an unavailable engine leaves the fallback eligible and does not wrap requests', () => {
  const p = page({ready:false});
  assert.equal(p.context.__cupitorBraveManaged, undefined);
  assert.equal(p.context.fetch, p.original);
  assert.deepEqual(p.queries.map(q => q.op), ['status']);
});

test('disabled native protection stands down the old blocker without installing new hooks', () => {
  const p = page({enabled:false});
  assert.equal(p.context.__cupitorBraveManaged, true);
  assert.equal(p.context.__cupitorBraveActive, undefined);
  assert.equal(p.context.fetch, p.original);
});

test('fetch consults the native matcher with the frame URL, method and resolved target', async () => {
  const p = page({match:q => ({blocked:q.target?.endsWith('/ads')})});
  await assert.rejects(p.context.fetch('/ads'), /Failed to fetch/);
  assert.equal(p.fetched.length, 0);
  const init = {method:'POST', body:'content'};
  assert.equal(await (await p.context.fetch('/player', init)).text(), 'allowed');
  assert.equal(p.fetched[0][1], init);
  assert.deepEqual(p.queries.filter(q => q.op === 'network'), [
    {op:'network', target:'https://study.example/ads', type:'xmlhttprequest', method:'GET', url:'https://study.example/video'},
    {op:'network', target:'https://study.example/player', type:'xmlhttprequest', method:'POST', url:'https://study.example/video'},
  ]);
});

test('maintained redirect resources and rewritten URLs are honored', async () => {
  const p = page({match:q => q.target?.endsWith('/redirect')
    ? {blocked:true, redirect:'data:application/json;base64,e30='}
    : {rewritten:'https://study.example/clean'}});
  const response = await p.context.fetch('/redirect');
  assert.deepEqual(await response.json(), {});
  assert.equal(response.headers.get('content-type'), 'application/json');
  assert.equal(p.fetched.length, 0);
  await p.context.fetch(new Request('https://study.example/content'));
  assert.equal(p.fetched[0][0].url, 'https://study.example/clean');
});

test('XHR blocks the remote send while preserving allowed request arguments', () => {
  const p = page({match:q => ({blocked:q.target?.endsWith('/ads')})});
  p.run(`const xhr = new XMLHttpRequest(); xhr.open('POST', '/ads', true); xhr.open('POST', '/content', false);`);
  assert.deepEqual(Array.from(p.opened[0]), ['GET', 'data:text/plain,', true]);
  assert.deepEqual(Array.from(p.opened[1]), ['POST', '/content', false]);
});

test('macOS reserved prompt transport and duplicate installation preserve one wrapper', async () => {
  const p = page({transport:'macos'});
  const wrapper = p.context.fetch;
  vm.runInContext(source, p.context);
  assert.equal(p.context.fetch, wrapper);
  await p.context.fetch('/content');
  assert.equal(p.queries.filter(q => q.op === 'network').length, 1);
});

test('a background WebKit view can start protection before prompt transport becomes available', () => {
  const p = page({prelude:`delete window.CupitorBraveNative; window.prompt = () => null;
    window.__cupitorBraveBootstrap = {ready:true,enabled:true};`});
  assert.equal(p.context.__cupitorBraveActive, true);
  assert.equal(p.context.__cupitorBraveBootstrap, undefined);
});
