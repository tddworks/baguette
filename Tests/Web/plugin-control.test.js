'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { loadBrowserModule } = require('./helpers/load-browser-module.js');

const MODULE_PATH = path.join(
  __dirname, '..', '..', 'Sources', 'Baguette', 'Resources', 'Web',
  'page/internal/plugins/plugin-control.js'
);

function PluginControl() {
  return loadBrowserModule(MODULE_PATH).Baguette._PluginControl;
}

const CHECKBOX = { kind: 'checkbox', arg: 'enabled', submit: 'Apply' };
const RADIO = { kind: 'radio', arg: 'appearance', submit: 'Set' };

// A panel mixing controls with a plain header row, which is the shape
// display.py actually returns.
const ROWS = [
  { title: 'Permissions' },
  { title: 'Camera', value: 'camera', state: 'on' },
  { title: 'Microphone', value: 'mic', state: 'off' },
  { title: 'Location', value: 'location', state: 'off' },
];

test('a panel with no control declares no ticks', () => {
  const Control = PluginControl();
  assert.equal(new Control(undefined).present, false);
  assert.equal(new Control({ kind: 'switch' }).present, false); // no arg
});

test('ticks start from what the device reported, not from empty', () => {
  // The panel opens showing the machine's actual state. Starting blank
  // would show every setting off and invite you to "fix" it.
  const Control = PluginControl();
  assert.deepEqual(new Control(CHECKBOX).initialTicks(ROWS), {
    camera: true, mic: false, location: false,
  });
});

test('a row with no state is not a control, so headers stay headers', () => {
  const Control = PluginControl();
  const control = new Control(CHECKBOX);
  assert.equal(control.isControlRow(ROWS[0]), false);
  assert.equal(control.isControlRow(ROWS[1]), true);
  assert.equal(Object.hasOwn(control.initialTicks(ROWS), 'Permissions'), false);
});

test('ticking a checkbox flips only that row', () => {
  const Control = PluginControl();
  const control = new Control(CHECKBOX);
  const next = control.toggle(control.initialTicks(ROWS), ROWS[2], ROWS);
  assert.deepEqual(next, { camera: true, mic: true, location: false });
});

test('ticking does not mutate the ticks it was given', () => {
  // The renderer holds the previous set while painting; mutating in
  // place would make "what changed" unanswerable.
  const Control = PluginControl();
  const control = new Control(CHECKBOX);
  const before = control.initialTicks(ROWS);
  control.toggle(before, ROWS[2], ROWS);
  assert.deepEqual(before, { camera: true, mic: false, location: false });
});

test('a radio turns its siblings off, and cannot be turned off by re-clicking', () => {
  // One-of-many: clicking the selected option again must leave it
  // selected rather than dropping the panel into "nothing chosen",
  // which is a state the device can't be in.
  const Control = PluginControl();
  const control = new Control(RADIO);
  const start = control.initialTicks(ROWS);
  assert.deepEqual(control.toggle(start, ROWS[2], ROWS), {
    camera: false, mic: true, location: false,
  });
  assert.deepEqual(control.toggle(start, ROWS[1], ROWS), {
    camera: true, mic: false, location: false,
  });
});

// A settings panel is normally several independent choices at once —
// display.py alone has appearance, contrast and text size. Without
// groups, one radio panel could only ever offer a single question, and
// picking "Dark" would silently unpick the text size.
const GROUPED = [
  { title: 'Appearance' },
  { title: 'Light', value: 'appearance:light', state: 'on', group: 'appearance' },
  { title: 'Dark', value: 'appearance:dark', state: 'off', group: 'appearance' },
  { title: 'Text size' },
  { title: 'Default', value: 'size:large', state: 'on', group: 'size' },
  { title: 'Largest', value: 'size:xxxl', state: 'off', group: 'size' },
];

test('a radio only unpicks its own group', () => {
  const Control = PluginControl();
  const control = new Control(RADIO);
  const next = control.toggle(control.initialTicks(GROUPED), GROUPED[2], GROUPED);

  assert.equal(next['appearance:dark'], true);
  assert.equal(next['appearance:light'], false);
  // The other question is untouched.
  assert.equal(next['size:large'], true);
  assert.equal(next['size:xxxl'], false);
});

test('picking in one group leaves the other groups unpending', () => {
  const Control = PluginControl();
  const control = new Control(RADIO);
  const next = control.toggle(control.initialTicks(GROUPED), GROUPED[5], GROUPED);
  assert.deepEqual(control.pending(next, GROUPED), ['size:large', 'size:xxxl']);
});

test('ungrouped radio rows behave as one group, as before', () => {
  const Control = PluginControl();
  const control = new Control(RADIO);
  const next = control.toggle(control.initialTicks(ROWS), ROWS[2], ROWS);
  assert.deepEqual(next, { camera: false, mic: true, location: false });
});

test('a checkbox ignores groups — ticking one leaves the rest alone', () => {
  // Grouping is a radio concept: it says which options are mutually
  // exclusive. Many-of-many has no such constraint to express.
  const Control = PluginControl();
  const control = new Control(CHECKBOX);
  const next = control.toggle(control.initialTicks(GROUPED), GROUPED[2], GROUPED);
  assert.equal(next['appearance:dark'], true);
  assert.equal(next['appearance:light'], true);
});

test('a row whose tick disagrees with the device is pending', () => {
  // This is the whole cost of batching, made visible: until Apply
  // returns, these rows show something the device has not confirmed.
  const Control = PluginControl();
  const control = new Control(CHECKBOX);
  const ticks = control.toggle(control.initialTicks(ROWS), ROWS[2], ROWS);
  assert.deepEqual(control.pending(ticks, ROWS), ['mic']);
});

test('nothing is pending before anything is ticked', () => {
  const Control = PluginControl();
  const control = new Control(CHECKBOX);
  const ticks = control.initialTicks(ROWS);
  assert.deepEqual(control.pending(ticks, ROWS), []);
  assert.equal(control.changed(ticks, ROWS), false);
});

test('ticking a row and ticking it back is not a change', () => {
  const Control = PluginControl();
  const control = new Control(CHECKBOX);
  let ticks = control.initialTicks(ROWS);
  ticks = control.toggle(ticks, ROWS[2], ROWS);
  ticks = control.toggle(ticks, ROWS[2], ROWS);
  assert.equal(control.changed(ticks, ROWS), false);
});

test('submitting sends every ticked value under the manifest key', () => {
  const Control = PluginControl();
  const control = new Control(CHECKBOX);
  const ticks = control.toggle(control.initialTicks(ROWS), ROWS[3], ROWS);
  assert.deepEqual(control.args(ticks, ROWS), { enabled: ['camera', 'location'] });
});

test('submitting sends an array even for a radio, so plugins have one shape', () => {
  const Control = PluginControl();
  const control = new Control(RADIO);
  const ticks = control.toggle(control.initialTicks(ROWS), ROWS[2], ROWS);
  assert.deepEqual(control.args(ticks, ROWS), { appearance: ['mic'] });
});

test('unticking everything submits an empty array, not nothing', () => {
  // "Turn all of these off" is a real instruction. Collapsing it to a
  // no-op would make the panel refuse the one edit it should accept.
  const Control = PluginControl();
  const control = new Control(CHECKBOX);
  const ticks = control.toggle(control.initialTicks(ROWS), ROWS[1], ROWS);
  assert.deepEqual(control.args(ticks, ROWS), { enabled: [] });
  assert.equal(control.changed(ticks, ROWS), true);
});

test('submitted values follow row order, so the plugin sees a stable list', () => {
  const Control = PluginControl();
  const control = new Control(CHECKBOX);
  let ticks = control.initialTicks(ROWS);
  ticks = control.toggle(ticks, ROWS[3], ROWS);
  ticks = control.toggle(ticks, ROWS[2], ROWS);
  assert.deepEqual(control.args(ticks, ROWS), { enabled: ['camera', 'mic', 'location'] });
});

test('a panel with no control submits nothing at all', () => {
  const Control = PluginControl();
  const control = new Control(undefined);
  assert.equal(control.args({}, ROWS), null);
  assert.deepEqual(control.initialTicks(ROWS), {});
  assert.equal(control.changed({}, ROWS), false);
});

test('the button label falls back when the manifest names none', () => {
  const Control = PluginControl();
  assert.equal(new Control({ kind: 'switch', arg: 'e' }).submitLabel, 'Apply');
  assert.equal(new Control(RADIO).submitLabel, 'Set');
});

test('the glyph family is reported for the host to draw', () => {
  const Control = PluginControl();
  assert.equal(new Control(CHECKBOX).kind, 'checkbox');
  assert.equal(new Control(RADIO).kind, 'radio');
});

test('a control kind the page cannot draw is refused, not passed through', () => {
  // `kind` is interpolated straight into `data-control` and `role`
  // attributes. The Swift parser restricts it to three values, but this
  // file must not depend on that: /plugins.json is the same untrusted
  // manifest text every other string here is escaped for, and one
  // malformed value would otherwise close the attribute and open a new
  // one. Same closed-set treatment `SEVERITIES` already gets.
  const Control = PluginControl();
  assert.equal(new Control({ kind: 'dial', arg: 'e' }).present, false);
  assert.equal(new Control({ kind: 'radio" data-x="injected', arg: 'e' }).present, false);
  assert.equal(new Control({ kind: 'dial', arg: 'e' }).kind, null);
});

test('a refused control kind ticks nothing and submits nothing', () => {
  // Refusing must be inert all the way through, not just at `kind` —
  // otherwise the rows would still tick while drawing no glyph.
  const Control = PluginControl();
  const control = new Control({ kind: 'dial', arg: 'e' });
  assert.equal(control.isControlRow({ state: 'on', value: 'x' }), false);
  assert.deepEqual(control.initialTicks(ROWS), {});
  assert.equal(control.args({}, ROWS), null);
});
