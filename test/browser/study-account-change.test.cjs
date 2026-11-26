const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

// Exercise the JavaScript actually sent by the native credential setter.
const main = fs.readFileSync(path.resolve(__dirname, '../../lib/main.dart'), 'utf8');
const setter = main.slice(main.indexOf('Future<void> _setGithubToken('), main.indexOf('Future<void> _showDeviceSignIn('));
const template = setter.match(/await study\.runJavaScript\('''([\s\S]*?)'''\)/)?.[1];
assert.ok(template, 'native credential changes contain a study-page reset');
const script = (reload = true) => template.replace("${reload ? 'location.reload();' : ''}", reload ? 'location.reload();' : '');

function page(blocked = false) {
  const saved = new Map([
    ['cupitor:account', JSON.stringify({login: 'alice', repo: 'data', branch: 'main'})],
    ['cupitor:practiceLog:swedish@alice', 'Alice private practice log'],
    ['cupitor:practiceLog:swedish', 'Owner private practice log'],
  ]);
  const document = {documentElement: {style: {visibility: 'visible'}}};
  const events = [];
  let reloads = 0;
  const context = {
    document,
    localStorage: {setItem(key, value) {if (blocked) throw new Error('Storage unavailable'); saved.set(key, value);}},
    CustomEvent: class {constructor(type) {this.type = type;}},
    window: {dispatchEvent(event) {events.push(event.type); assert.equal(JSON.parse(saved.get('cupitor:account')).login, null);}},
    location: {reload() {
      reloads++;
      assert.equal(document.documentElement.style.visibility, 'hidden');
      assert.equal(JSON.parse(saved.get('cupitor:account')).login, null);
    }},
  };
  return {saved, context, events, reloads: () => reloads};
}

test('a native credential change hides and resets the previous identity before reloading, preserving all account data', () => {
  const p = page();
  vm.runInNewContext(script(), p.context);
  assert.deepEqual(JSON.parse(p.saved.get('cupitor:account')), {login: null, repo: null, branch: null});
  assert.equal(p.saved.get('cupitor:practiceLog:swedish@alice'), 'Alice private practice log');
  assert.equal(p.saved.get('cupitor:practiceLog:swedish'), 'Owner private practice log');
  assert.deepEqual(p.events, ['cupitor:account-changed']);
  assert.equal(p.reloads(), 1);
});

test('blocked account storage leaves the old page hidden and rejects the reset for the native blank-page fallback', () => {
  const p = page(true);
  assert.throws(() => vm.runInNewContext(script(), p.context), /Storage unavailable/);
  assert.equal(p.context.document.documentElement.style.visibility, 'hidden');
  assert.equal(p.reloads(), 0);
  assert.equal(p.saved.get('cupitor:practiceLog:swedish@alice'), 'Alice private practice log');
});

test('the pre-change reset does not reload with the old token; the final reset discards late old identity responses', () => {
  const p = page();
  vm.runInNewContext(script(false), p.context);
  assert.equal(p.reloads(), 0);
  assert.equal(JSON.parse(p.saved.get('cupitor:account')).login, null);
  // A response already in flight before credential replacement can arrive
  // while native preferences are being saved.
  p.saved.set('cupitor:account', JSON.stringify({login: 'alice'}));
  vm.runInNewContext(script(true), p.context);
  assert.equal(p.reloads(), 1);
  assert.equal(JSON.parse(p.saved.get('cupitor:account')).login, null);
  assert.equal(p.saved.get('cupitor:practiceLog:swedish@alice'), 'Alice private practice log');
});
