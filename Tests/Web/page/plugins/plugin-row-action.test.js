import test from 'node:test';
import assert from 'node:assert/strict';
import { PluginRowAction } from '../../../../Sources/Baguette/Resources/Web/page/internal/plugins/plugin-row-action.js';

const FRAME = { x: 24, y: 380, width: 44, height: 44 };

test('should box its own frame when a highlight row is clicked', () => {
  assert.deepEqual(
    new PluginRowAction('highlight').intent({ title: 'Button has no label', frame: FRAME }),
    { kind: 'highlight', frame: FRAME }
  );
});

test('should aim a tap row at the centre of its frame, in device points', () => {
  // Same arithmetic the AX inspector's "tap" button does on a node —
  // the frame arrives in the coordinate space gestures already use, so
  // the centre needs no scaling.
  assert.deepEqual(
    new PluginRowAction('tap').intent({ title: 'Submit', frame: FRAME }),
    { kind: 'tap', point: { x: 46, y: 402 } }
  );
});

test('should carry the text the plugin nominated when a copy row is clicked', () => {
  assert.deepEqual(
    new PluginRowAction('copy').intent({ title: 'Deep link', copy: 'myapp://order/42' }),
    { kind: 'copy', text: 'myapp://order/42' }
  );
});

test('should invoke its own command with its args when a run row is clicked', () => {
  // The only action that hands control back to the plugin: the row
  // names a command and the arguments to call it with, and the panel
  // re-renders from whatever that command answers.
  assert.deepEqual(
    new PluginRowAction('run').intent({ title: 'Dark', run: 'set', args: { appearance: 'dark' } }),
    { kind: 'run', command: 'set', args: { appearance: 'dark' } }
  );
});

test('should still invoke its command when a run row has no args', () => {
  // "Reset to defaults" needs no arguments; args default to an empty
  // object so the caller has one shape to post.
  assert.deepEqual(
    new PluginRowAction('run').intent({ title: 'Reset', run: 'reset' }),
    { kind: 'run', command: 'reset', args: {} }
  );
});

test('should hand its text to the panel prompt when a fill row is clicked', () => {
  // The other actions do something *with* a row. This one types it into
  // the field above, which is what a list under a text box means: the
  // deep-link panel used to open a bare `account://` on click, when what
  // you want is that scheme in the box ready for the rest of the path.
  assert.deepEqual(
    new PluginRowAction('fill').intent({ title: 'account://', fill: 'account://' }),
    { kind: 'fill', text: 'account://' }
  );
});

test('should fill with its own text, not the label it displays', () => {
  assert.deepEqual(
    new PluginRowAction('fill').intent({ title: 'Account (SpringBoard)', fill: 'account://' }),
    { kind: 'fill', text: 'account://' }
  );
});

test('should leave a fill row inert when it has nothing to fill', () => {
  assert.equal(new PluginRowAction('fill').intent({ title: 'Nothing to report' }), null);
  assert.equal(new PluginRowAction('fill').actionable({ title: 'Nothing to report' }), false);
});

test('should leave a run row inert when it names no command', () => {
  assert.equal(new PluginRowAction('run').intent({ title: 'Dark' }), null);
  assert.equal(new PluginRowAction('run').actionable({ title: 'Dark' }), false);
  assert.equal(new PluginRowAction('run').actionable({ title: 'Dark', run: 'set' }), true);
});

test('should make a run row clickable when it has no frame', () => {
  // Clickability follows the action: a settings row has no on-screen
  // rect, and demanding one would make every row inert.
  assert.equal(new PluginRowAction('run').actionable({ run: 'set' }), true);
});

test('should do nothing when a row has nothing to act on', () => {
  // A plugin may return rows that carry no frame — the docs say such a
  // row simply isn't clickable, rather than clicking doing something
  // arbitrary like tapping the origin.
  assert.equal(new PluginRowAction('highlight').intent({ title: 'All clear' }), null);
  assert.equal(new PluginRowAction('tap').intent({ title: 'All clear' }), null);
  assert.equal(new PluginRowAction('copy').intent({ title: 'All clear' }), null);
});

test('should make a copy row actionable without a frame, but not a tap row', () => {
  // Clickability follows what the action needs, not a blanket "has a
  // frame" — a copy row never needed one.
  assert.equal(new PluginRowAction('copy').actionable({ copy: 'text' }), true);
  assert.equal(new PluginRowAction('tap').actionable({ copy: 'text' }), false);
  assert.equal(new PluginRowAction('tap').actionable({ frame: FRAME }), true);
  assert.equal(new PluginRowAction('highlight').actionable({ frame: FRAME }), true);
});

test('should leave its rows inert when the panel declared no rowAction', () => {
  assert.equal(new PluginRowAction(undefined).intent({ frame: FRAME }), null);
  assert.equal(new PluginRowAction(undefined).actionable({ frame: FRAME }), false);
});

test('should leave an unknown rowAction inert rather than guess at it', () => {
  // A manifest is untrusted text. A rowAction baguette doesn't know is
  // not an invitation to pick the closest match.
  assert.equal(new PluginRowAction('detonate').intent({ frame: FRAME }), null);
  assert.equal(new PluginRowAction('detonate').actionable({ frame: FRAME }), false);
});

test('should resolve a zero-sized frame to its own origin', () => {
  assert.deepEqual(
    new PluginRowAction('tap').intent({ frame: { x: 10, y: 20, width: 0, height: 0 } }),
    { kind: 'tap', point: { x: 10, y: 20 } }
  );
});
