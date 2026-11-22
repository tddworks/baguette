import test from 'node:test';
import assert from 'node:assert/strict';
import { pageActions } from '../../../Sources/Baguette/Resources/Web/page/internal/actions.js';

// The page's controls say what they do (`data-action`, and `data-arg` when it
// takes one); each concern registers its own verbs, and one listener runs
// the verb a click names — so a new control is markup plus one registration.

/** A click on an element carrying `data`, as the delegated listener sees it. */
function clickOn(dataset) {
  const el = { dataset };
  return { target: { closest: (sel) => (sel === '[data-action]' ? el : null) } };
}

function root() {
  const listeners = {};
  return { listeners, addEventListener: (type, fn) => { listeners[type] = fn; } };
}

test('should run the verb a control names, with its argument', () => {
  const ran = [];
  const actions = pageActions();
  actions.on('setFormat', (format) => ran.push(['setFormat', format]));
  actions.on('rotate', () => ran.push(['rotate']));
  const page = root();
  actions.listen(page);
  page.listeners.click(clickOn({ action: 'setFormat', arg: 'webrtc' }));
  page.listeners.click(clickOn({ action: 'rotate' }));
  assert.deepEqual(ran, [['setFormat', 'webrtc'], ['rotate']]);
});

test('should read true and false as the flags they are', () => {
  const got = [];
  const actions = pageActions();
  actions.on('handheldMenu', (open) => got.push(open));
  actions.run('handheldMenu', 'false');
  actions.run('handheldMenu', 'true');
  assert.deepEqual(got, [false, true]);
});

test('should do nothing for a verb no concern registered, or a click on no control', () => {
  const actions = pageActions();
  const page = root();
  actions.listen(page);
  assert.doesNotThrow(() => actions.run('nothing'));
  assert.doesNotThrow(() => page.listeners.click({ target: { closest: () => null } }));
});

test('should say whether a verb is registered', () => {
  const actions = pageActions();
  actions.on('rotate', () => {});
  assert.equal(actions.has('rotate'), true);
  assert.equal(actions.has('shake'), false);
});
