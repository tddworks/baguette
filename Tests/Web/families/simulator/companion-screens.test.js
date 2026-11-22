import test from 'node:test';
import assert from 'node:assert/strict';
import { CompanionScreens } from '../../../../Sources/Baguette/Resources/Web/families/simulator/internal/companion-screens.js';

function entriesFor(payload) {
  const map = {};
  for (const entry of CompanionScreens.from(payload).entries()) map[entry.id] = entry;
  return map;
}

test('should give every companion screen an entry, in a stable order', () => {
  const ids = CompanionScreens.from(null).entries().map((e) => e.id);
  assert.deepEqual(ids, ['external', 'watch']);
});

test('should offer an attached external display ready to open, labelled by its size', () => {
  const external = entriesFor({ external: { available: true, width: 800, height: 480 } }).external;
  assert.equal(external.status, 'ready');
  assert.equal(external.label, 'External display');
  assert.ok(external.canOpen);
  assert.equal(external.detail, '800 \u00d7 480');
});

test('should explain how to attach one when no external display is attached', () => {
  const external = entriesFor({ external: { available: false } }).external;
  assert.equal(external.status, 'absent');
  assert.ok(!external.canOpen);
  assert.ok(external.instructions.length > 0);
  assert.ok(external.instructions.some((step) => /External Displays/.test(step)));
});

test('should offer a booted paired watch ready, labelled with its own name', () => {
  const watch = entriesFor({
    watch: { available: true, udid: 'W-1', name: 'Apple Watch Ultra 3', state: 'Booted' },
  }).watch;
  assert.equal(watch.status, 'ready');
  assert.equal(watch.label, 'Apple Watch Ultra 3');
  assert.equal(watch.udid, 'W-1');
  assert.ok(watch.canOpen);
});

test('should ask for booting, not instructions, when the paired watch is not booted', () => {
  const watch = entriesFor({
    watch: { available: true, udid: 'W-1', name: 'Apple Watch Ultra 3', state: 'Shutdown' },
  }).watch;
  assert.equal(watch.status, 'needs-boot');
  assert.ok(!watch.canOpen);
  assert.equal(watch.udid, 'W-1');
});

test('should explain how to pair one when the phone has no paired watch', () => {
  const watch = entriesFor({ watch: { available: false } }).watch;
  assert.equal(watch.status, 'absent');
  assert.ok(watch.instructions.some((step) => /simctl pair/.test(step)));
  assert.equal(watch.label, 'Apple Watch');
});

test('should read nothing available when the payload is one the server never sent', () => {
  for (const payload of [null, undefined, 'nope', 42, {}, { watch: 'yes' }]) {
    for (const entry of CompanionScreens.from(payload).entries()) {
      assert.equal(entry.status, 'absent', `${JSON.stringify(payload)} → ${entry.id}`);
      assert.ok(!entry.canOpen);
    }
  }
});

test('should not stream a watch when it is marked available with no udid', () => {
  const watch = entriesFor({ watch: { available: true, state: 'Booted' } }).watch;
  assert.equal(watch.status, 'absent');
  assert.ok(!watch.canOpen);
});

test('should name as openable just the screens a click could actually show', () => {
  const screens = CompanionScreens.from({
    external: { available: true, width: 800, height: 480 },
    watch: { available: true, udid: 'W-1', name: 'Watch', state: 'Shutdown' },
  });
  assert.deepEqual(screens.openable().map((e) => e.id), ['external']);
});

// Re-probing happens whenever the page regains focus, because attaching
// a display happens in another app entirely. That makes "did anything
// change?" a hot path: answering "no" has to be free, or every tab-back
// tears down and rebuilds live streams.
test('should see no change when two answers are identical', () => {
  const a = CompanionScreens.from({
    external: { available: true, width: 800, height: 480 },
    watch: { available: true, udid: 'W-1', name: 'Watch', state: 'Booted' },
  });
  const b = CompanionScreens.from({
    external: { available: true, width: 800, height: 480 },
    watch: { available: true, udid: 'W-1', name: 'Watch', state: 'Booted' },
  });
  assert.ok(a.sameAs(b));
});

test('should see a change when a display appeared', () => {
  const before = CompanionScreens.from({ external: { available: false } });
  const after = CompanionScreens.from({
    external: { available: true, width: 800, height: 480 },
  });
  assert.ok(!before.sameAs(after));
});

test('should see a change when a display went away', () => {
  const before = CompanionScreens.from({
    external: { available: true, width: 800, height: 480 },
  });
  const after = CompanionScreens.from({ external: { available: false } });
  assert.ok(!before.sameAs(after));
});

// A watch that booted while you were elsewhere should light its slot
// without a reload, same as a display that got attached.
test('should see a change when a watch changed boot state', () => {
  const before = CompanionScreens.from({
    watch: { available: true, udid: 'W-1', name: 'Watch', state: 'Shutdown' },
  });
  const after = CompanionScreens.from({
    watch: { available: true, udid: 'W-1', name: 'Watch', state: 'Booted' },
  });
  assert.ok(!before.sameAs(after));
});

// Resizing the attached display changes what the pane should draw.
test('should see a change when a display changed size', () => {
  const before = CompanionScreens.from({
    external: { available: true, width: 800, height: 480 },
  });
  const after = CompanionScreens.from({
    external: { available: true, width: 1280, height: 720 },
  });
  assert.ok(!before.sameAs(after));
});

test('should see a change, not crash, when compared against nothing', () => {
  const screens = CompanionScreens.from({ external: { available: true, width: 800, height: 480 } });
  assert.ok(!screens.sameAs(null));
  assert.ok(!screens.sameAs(undefined));
});
