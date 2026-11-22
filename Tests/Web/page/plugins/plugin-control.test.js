import test from 'node:test';
import assert from 'node:assert/strict';
import { PluginControl } from '../../../../Sources/Baguette/Resources/Web/page/internal/plugins/plugin-control.js';

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

test('should declare no ticks when the panel has no control', () => {
  assert.equal(new PluginControl(undefined).present, false);
  assert.equal(new PluginControl({ kind: 'switch' }).present, false); // no arg
});

test('should start the ticks from what the device reported, not from empty', () => {
  // The panel opens showing the machine's actual state. Starting blank
  // would show every setting off and invite you to "fix" it.
  assert.deepEqual(new PluginControl(CHECKBOX).initialTicks(ROWS), {
    camera: true, mic: false, location: false,
  });
});

test('should keep a row with no state a header, not a control', () => {
  const control = new PluginControl(CHECKBOX);
  assert.equal(control.isControlRow(ROWS[0]), false);
  assert.equal(control.isControlRow(ROWS[1]), true);
  assert.equal(Object.hasOwn(control.initialTicks(ROWS), 'Permissions'), false);
});

test('should flip only that row when a checkbox is ticked', () => {
  const control = new PluginControl(CHECKBOX);
  const next = control.toggle(control.initialTicks(ROWS), ROWS[2], ROWS);
  assert.deepEqual(next, { camera: true, mic: true, location: false });
});

test('should not mutate the ticks it was given when ticking', () => {
  // The renderer holds the previous set while painting; mutating in
  // place would make "what changed" unanswerable.
  const control = new PluginControl(CHECKBOX);
  const before = control.initialTicks(ROWS);
  control.toggle(before, ROWS[2], ROWS);
  assert.deepEqual(before, { camera: true, mic: false, location: false });
});

test('should turn a radio\'s siblings off, and keep it on when it is re-clicked', () => {
  // One-of-many: clicking the selected option again must leave it
  // selected rather than dropping the panel into "nothing chosen",
  // which is a state the device can't be in.
  const control = new PluginControl(RADIO);
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

test('should unpick only its own group when a radio is picked', () => {
  const control = new PluginControl(RADIO);
  const next = control.toggle(control.initialTicks(GROUPED), GROUPED[2], GROUPED);

  assert.equal(next['appearance:dark'], true);
  assert.equal(next['appearance:light'], false);
  // The other question is untouched.
  assert.equal(next['size:large'], true);
  assert.equal(next['size:xxxl'], false);
});

test('should leave the other groups unpending when one group is picked in', () => {
  const control = new PluginControl(RADIO);
  const next = control.toggle(control.initialTicks(GROUPED), GROUPED[5], GROUPED);
  assert.deepEqual(control.pending(next, GROUPED), ['size:large', 'size:xxxl']);
});

test('should treat ungrouped radio rows as one group, as before', () => {
  const control = new PluginControl(RADIO);
  const next = control.toggle(control.initialTicks(ROWS), ROWS[2], ROWS);
  assert.deepEqual(next, { camera: false, mic: true, location: false });
});

test('should leave the rest alone when a checkbox is ticked, whatever its group', () => {
  // Grouping is a radio concept: it says which options are mutually
  // exclusive. Many-of-many has no such constraint to express.
  const control = new PluginControl(CHECKBOX);
  const next = control.toggle(control.initialTicks(GROUPED), GROUPED[2], GROUPED);
  assert.equal(next['appearance:dark'], true);
  assert.equal(next['appearance:light'], true);
});

test('should mark a row pending when its tick disagrees with the device', () => {
  // This is the whole cost of batching, made visible: until Apply
  // returns, these rows show something the device has not confirmed.
  const control = new PluginControl(CHECKBOX);
  const ticks = control.toggle(control.initialTicks(ROWS), ROWS[2], ROWS);
  assert.deepEqual(control.pending(ticks, ROWS), ['mic']);
});

test('should mark nothing pending before anything is ticked', () => {
  const control = new PluginControl(CHECKBOX);
  const ticks = control.initialTicks(ROWS);
  assert.deepEqual(control.pending(ticks, ROWS), []);
  assert.equal(control.changed(ticks, ROWS), false);
});

test('should see no change when a row is ticked and ticked back', () => {
  const control = new PluginControl(CHECKBOX);
  let ticks = control.initialTicks(ROWS);
  ticks = control.toggle(ticks, ROWS[2], ROWS);
  ticks = control.toggle(ticks, ROWS[2], ROWS);
  assert.equal(control.changed(ticks, ROWS), false);
});

test('should submit every ticked value under the manifest key', () => {
  const control = new PluginControl(CHECKBOX);
  const ticks = control.toggle(control.initialTicks(ROWS), ROWS[3], ROWS);
  assert.deepEqual(control.args(ticks, ROWS), { enabled: ['camera', 'location'] });
});

test('should submit an array even for a radio, so plugins have one shape', () => {
  const control = new PluginControl(RADIO);
  const ticks = control.toggle(control.initialTicks(ROWS), ROWS[2], ROWS);
  assert.deepEqual(control.args(ticks, ROWS), { appearance: ['mic'] });
});

test('should submit an empty array, not nothing, when everything is unticked', () => {
  // "Turn all of these off" is a real instruction. Collapsing it to a
  // no-op would make the panel refuse the one edit it should accept.
  const control = new PluginControl(CHECKBOX);
  const ticks = control.toggle(control.initialTicks(ROWS), ROWS[1], ROWS);
  assert.deepEqual(control.args(ticks, ROWS), { enabled: [] });
  assert.equal(control.changed(ticks, ROWS), true);
});

test('should submit values in row order, so the plugin sees a stable list', () => {
  const control = new PluginControl(CHECKBOX);
  let ticks = control.initialTicks(ROWS);
  ticks = control.toggle(ticks, ROWS[3], ROWS);
  ticks = control.toggle(ticks, ROWS[2], ROWS);
  assert.deepEqual(control.args(ticks, ROWS), { enabled: ['camera', 'mic', 'location'] });
});

test('should submit nothing at all when the panel has no control', () => {
  const control = new PluginControl(undefined);
  assert.equal(control.args({}, ROWS), null);
  assert.deepEqual(control.initialTicks(ROWS), {});
  assert.equal(control.changed({}, ROWS), false);
});

test('should fall back to a button label when the manifest names none', () => {
  assert.equal(new PluginControl({ kind: 'switch', arg: 'e' }).submitLabel, 'Apply');
  assert.equal(new PluginControl(RADIO).submitLabel, 'Set');
});

test('should report the glyph family for the host to draw', () => {
  assert.equal(new PluginControl(CHECKBOX).kind, 'checkbox');
  assert.equal(new PluginControl(RADIO).kind, 'radio');
});

test('should refuse, not pass through, a control kind the page cannot draw', () => {
  // `kind` is interpolated straight into `data-control` and `role`
  // attributes. The Swift parser restricts it to three values, but this
  // file must not depend on that: /plugins.json is the same untrusted
  // manifest text every other string here is escaped for, and one
  // malformed value would otherwise close the attribute and open a new
  // one. Same closed-set treatment `SEVERITIES` already gets.
  assert.equal(new PluginControl({ kind: 'dial', arg: 'e' }).present, false);
  assert.equal(new PluginControl({ kind: 'radio" data-x="injected', arg: 'e' }).present, false);
  assert.equal(new PluginControl({ kind: 'dial', arg: 'e' }).kind, null);
});

test('should tick nothing and submit nothing when the control kind was refused', () => {
  // Refusing must be inert all the way through, not just at `kind` —
  // otherwise the rows would still tick while drawing no glyph.
  const control = new PluginControl({ kind: 'dial', arg: 'e' });
  assert.equal(control.isControlRow({ state: 'on', value: 'x' }), false);
  assert.deepEqual(control.initialTicks(ROWS), {});
  assert.equal(control.args({}, ROWS), null);
});
