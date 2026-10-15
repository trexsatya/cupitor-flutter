// Run the reader's actual selection-change script with a small DOM boundary.
// No npm packages are needed: selection/range APIs are the test inputs here.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const dart = fs.readFileSync(new URL('../../lib/epub_reader.dart', import.meta.url), 'utf8');
const script = dart.split('  function fullText() {')[1].split('  // ── Sentence wrapping')[0];
assert.ok(script, 'selection script must be present');
let selected = '';
let timer;
const events = [];
const messages = [];
const context = vm.createContext({
  document: {body: {innerText: 'Före. Sökbar svensk text. Efter.'},
    addEventListener(type, handler) { if (type === 'selectionchange') events.push(handler); }},
  window: {getSelection() {return {toString: () => selected,
    getRangeAt: () => ({getBoundingClientRect: () => ({left: 10, top: 50, width: 80})})};}},
  post: message => messages.push(message),
  setTimeout: fn => {timer = fn; return 1;},
  clearTimeout: () => {timer = null;},
});
// Dart unescapes the backslashes in this non-raw JS string.
vm.runInContext(('function fullText() {' + script).replaceAll('\\\\', '\\'), context);
function change(text) {
  selected = text;
  events[0]();
  timer();
}
change('Sökbar svensk text.');
assert.equal(messages[0].type, 'select');
assert.equal(messages[0].text, selected);
assert.equal(messages[0].prefix, 'Före. ');
change(selected);
assert.equal(messages.length, 1, 'unchanged selections are debounced');
change('');
assert.equal(messages[1].type, 'selectionCleared');
change('Sökbar svensk text.');
assert.equal(messages[2].type, 'select', 'same text can be selected again after clearing');
assert.equal(messages[2].x, 50);
console.log('Reader selection lifecycle: passed');
