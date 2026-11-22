'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { loadBrowserModule } = require('./helpers/load-browser-module.js');

const MODULE_PATH = path.join(
  __dirname, '..', '..', 'Sources', 'Baguette', 'Resources', 'Web',
  'page/internal/plugins/plugin-row-action.js'
);

function PluginRowAction() {
  return loadBrowserModule(MODULE_PATH).Baguette._PluginRowAction;
}

const FRAME = { x: 24, y: 380, width: 44, height: 44 };

test('a highlight row asks for its own frame to be boxed', () => {
  const Action = PluginRowAction();
  assert.deepEqual(
    new Action('highlight').intent({ title: 'Button has no label', frame: FRAME }),
    { kind: 'highlight', frame: FRAME }
  );
});

test('a tap row aims at the centre of its frame, in device points', () => {
  // Same arithmetic the AX inspector's "tap" button does on a node —
  // the frame arrives in the coordinate space gestures already use, so
  // the centre needs no scaling.
  const Action = PluginRowAction();
  assert.deepEqual(
    new Action('tap').intent({ title: 'Submit', frame: FRAME }),
    { kind: 'tap', point: { x: 46, y: 402 } }
  );
});

test('a copy row carries the text the plugin nominated', () => {
  const Action = PluginRowAction();
  assert.deepEqual(
    new Action('copy').intent({ title: 'Deep link', copy: 'myapp://order/42' }),
    { kind: 'copy', text: 'myapp://order/42' }
  );
});

test('a run row asks for its own command to be invoked with its args', () => {
  // The only action that hands control back to the plugin: the row
  // names a command and the arguments to call it with, and the panel
  // re-renders from whatever that command answers.
  const Action = PluginRowAction();
  assert.deepEqual(
    new Action('run').intent({ title: 'Dark', run: 'set', args: { appearance: 'dark' } }),
    { kind: 'run', command: 'set', args: { appearance: 'dark' } }
  );
});

test('a run row without args still invokes its command', () => {
  // "Reset to defaults" needs no arguments; args default to an empty
  // object so the caller has one shape to post.
  const Action = PluginRowAction();
  assert.deepEqual(
    new Action('run').intent({ title: 'Reset', run: 'reset' }),
    { kind: 'run', command: 'reset', args: {} }
  );
});

test('a fill row hands its text to the panel prompt', () => {
  // The other actions do something *with* a row. This one types it into
  // the field above, which is what a list under a text box means: the
  // deep-link panel used to open a bare `account://` on click, when what
  // you want is that scheme in the box ready for the rest of the path.
  const Action = PluginRowAction();
  assert.deepEqual(
    new Action('fill').intent({ title: 'account://', fill: 'account://' }),
    { kind: 'fill', text: 'account://' }
  );
});

test('a fill row uses its own text, not the label it displays', () => {
  const Action = PluginRowAction();
  assert.deepEqual(
    new Action('fill').intent({ title: 'Account (SpringBoard)', fill: 'account://' }),
    { kind: 'fill', text: 'account://' }
  );
});

test('a row with nothing to fill is inert', () => {
  const Action = PluginRowAction();
  assert.equal(new Action('fill').intent({ title: 'Nothing to report' }), null);
  assert.equal(new Action('fill').actionable({ title: 'Nothing to report' }), false);
});

test('a run row naming no command is inert', () => {
  const Action = PluginRowAction();
  assert.equal(new Action('run').intent({ title: 'Dark' }), null);
  assert.equal(new Action('run').actionable({ title: 'Dark' }), false);
  assert.equal(new Action('run').actionable({ title: 'Dark', run: 'set' }), true);
});

test('a run row does not need a frame to be clickable', () => {
  // Clickability follows the action: a settings row has no on-screen
  // rect, and demanding one would make every row inert.
  const Action = PluginRowAction();
  assert.equal(new Action('run').actionable({ run: 'set' }), true);
});

test('a row with nothing to act on means nothing happens', () => {
  // A plugin may return rows that carry no frame — the docs say such a
  // row simply isn't clickable, rather than clicking doing something
  // arbitrary like tapping the origin.
  const Action = PluginRowAction();
  assert.equal(new Action('highlight').intent({ title: 'All clear' }), null);
  assert.equal(new Action('tap').intent({ title: 'All clear' }), null);
  assert.equal(new Action('copy').intent({ title: 'All clear' }), null);
});

test('a copy row is actionable without a frame, a tap row is not', () => {
  // Clickability follows what the action needs, not a blanket "has a
  // frame" — a copy row never needed one.
  const Action = PluginRowAction();
  assert.equal(new Action('copy').actionable({ copy: 'text' }), true);
  assert.equal(new Action('tap').actionable({ copy: 'text' }), false);
  assert.equal(new Action('tap').actionable({ frame: FRAME }), true);
  assert.equal(new Action('highlight').actionable({ frame: FRAME }), true);
});

test('a panel that declared no rowAction leaves its rows inert', () => {
  const Action = PluginRowAction();
  assert.equal(new Action(undefined).intent({ frame: FRAME }), null);
  assert.equal(new Action(undefined).actionable({ frame: FRAME }), false);
});

test('an unknown rowAction is inert rather than guessed at', () => {
  // A manifest is untrusted text. A rowAction baguette doesn't know is
  // not an invitation to pick the closest match.
  const Action = PluginRowAction();
  assert.equal(new Action('detonate').intent({ frame: FRAME }), null);
  assert.equal(new Action('detonate').actionable({ frame: FRAME }), false);
});

test('a zero-sized frame still resolves to its own origin', () => {
  const Action = PluginRowAction();
  assert.deepEqual(
    new Action('tap').intent({ frame: { x: 10, y: 20, width: 0, height: 0 } }),
    { kind: 'tap', point: { x: 10, y: 20 } }
  );
});
