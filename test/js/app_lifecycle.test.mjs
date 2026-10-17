import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

// Execute the exact template used by the native bridge, with its JSON payload.
const source = readFileSync(new URL('../../lib/dialog_app_lifecycle.dart', import.meta.url), 'utf8');
const template = source.match(/const kDialogAppLifecycleJs = r'''([\s\S]*?)''';/)[1];
function page() {
  const window = new EventTarget();
  const context = vm.createContext({window, CustomEvent});
  return {
    window,
    send(state, isForeground) {
      vm.runInContext(template.replace('__CUPITOR_APP_LIFECYCLE__', JSON.stringify({state, isForeground})), context);
    },
  };
}

test('a background signal pauses a webapp timer and resume releases it', () => {
  const {window, send} = page();
  let timerSuspended = false;
  const states = [];
  window.addEventListener('cupitorAppLifecycle', event => {
    timerSuspended = !event.detail.isForeground;
    states.push(event.detail.state);
    assert.equal(window.CupitorAppLifecycle, event.detail);
  });
  send('inactive', false);
  assert.equal(timerSuspended, true);
  send('hidden', false);
  send('paused', false);
  send('resumed', true);
  assert.equal(timerSuspended, false);
  assert.deepEqual(states, ['inactive', 'hidden', 'paused', 'resumed']);
});

test('late scripts can read an immutable snapshot after missing the event', () => {
  const {window, send} = page();
  send('paused', false);
  const previous = window.CupitorAppLifecycle;
  assert.equal(previous.isForeground, false);
  assert.equal(Object.isFrozen(previous), true);
  send('resumed', true);
  assert.equal(window.CupitorAppLifecycle.isForeground, true);
  assert.equal(previous.state, 'paused');
});
