'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { loadBrowserModule } = require('./helpers/load-browser-module.js');

const MODULE_PATH = path.join(
  __dirname, '..', '..', 'Sources', 'Baguette', 'Resources', 'Web',
  'families', 'simulator', 'companion-screens.js'
);

function CompanionScreens() {
  return loadBrowserModule(MODULE_PATH).Baguette._CompanionScreens;
}

function entriesFor(payload) {
  const map = {};
  for (const entry of CompanionScreens().from(payload).entries()) map[entry.id] = entry;
  return map;
}

test('every companion screen gets an entry, in a stable order', () => {
  const ids = CompanionScreens().from(null).entries().map((e) => e.id);
  assert.deepEqual(ids, ['external', 'watch']);
});

test('an attached external display is ready to open, labelled by its size', () => {
  const external = entriesFor({ external: { available: true, width: 800, height: 480 } }).external;
  assert.equal(external.status, 'ready');
  assert.equal(external.label, 'External display');
  assert.ok(external.canOpen);
  assert.equal(external.detail, '800 \u00d7 480');
});

test('no external display attached explains how to attach one', () => {
  const external = entriesFor({ external: { available: false } }).external;
  assert.equal(external.status, 'absent');
  assert.ok(!external.canOpen);
  assert.ok(external.instructions.length > 0);
  assert.ok(external.instructions.some((step) => /External Displays/.test(step)));
});

test('a booted paired watch is ready, and is labelled with its own name', () => {
  const watch = entriesFor({
    watch: { available: true, udid: 'W-1', name: 'Apple Watch Ultra 3', state: 'Booted' },
  }).watch;
  assert.equal(watch.status, 'ready');
  assert.equal(watch.label, 'Apple Watch Ultra 3');
  assert.equal(watch.udid, 'W-1');
  assert.ok(watch.canOpen);
});

test('a paired watch that is not booted needs booting, not instructions', () => {
  const watch = entriesFor({
    watch: { available: true, udid: 'W-1', name: 'Apple Watch Ultra 3', state: 'Shutdown' },
  }).watch;
  assert.equal(watch.status, 'needs-boot');
  assert.ok(!watch.canOpen);
  assert.equal(watch.udid, 'W-1');
});

test('a phone with no paired watch explains how to pair one', () => {
  const watch = entriesFor({ watch: { available: false } }).watch;
  assert.equal(watch.status, 'absent');
  assert.ok(watch.instructions.some((step) => /simctl pair/.test(step)));
  assert.equal(watch.label, 'Apple Watch');
});

test('a payload the server never sent reads as nothing available', () => {
  for (const payload of [null, undefined, 'nope', 42, {}, { watch: 'yes' }]) {
    for (const entry of CompanionScreens().from(payload).entries()) {
      assert.equal(entry.status, 'absent', `${JSON.stringify(payload)} → ${entry.id}`);
      assert.ok(!entry.canOpen);
    }
  }
});

test('a watch marked available with no udid cannot be streamed', () => {
  const watch = entriesFor({ watch: { available: true, state: 'Booted' } }).watch;
  assert.equal(watch.status, 'absent');
  assert.ok(!watch.canOpen);
});

test('openable names just the screens a click could actually show', () => {
  const screens = CompanionScreens().from({
    external: { available: true, width: 800, height: 480 },
    watch: { available: true, udid: 'W-1', name: 'Watch', state: 'Shutdown' },
  });
  assert.deepEqual(screens.openable().map((e) => e.id), ['external']);
});

// Re-probing happens whenever the page regains focus, because attaching
// a display happens in another app entirely. That makes "did anything
// change?" a hot path: answering "no" has to be free, or every tab-back
// tears down and rebuilds live streams.
test('two identical answers compare equal', () => {
  const a = CompanionScreens().from({
    external: { available: true, width: 800, height: 480 },
    watch: { available: true, udid: 'W-1', name: 'Watch', state: 'Booted' },
  });
  const b = CompanionScreens().from({
    external: { available: true, width: 800, height: 480 },
    watch: { available: true, udid: 'W-1', name: 'Watch', state: 'Booted' },
  });
  assert.ok(a.sameAs(b));
});

test('a display that appeared is a change', () => {
  const before = CompanionScreens().from({ external: { available: false } });
  const after = CompanionScreens().from({
    external: { available: true, width: 800, height: 480 },
  });
  assert.ok(!before.sameAs(after));
});

test('a display that went away is a change', () => {
  const before = CompanionScreens().from({
    external: { available: true, width: 800, height: 480 },
  });
  const after = CompanionScreens().from({ external: { available: false } });
  assert.ok(!before.sameAs(after));
});

// A watch that booted while you were elsewhere should light its slot
// without a reload, same as a display that got attached.
test('a watch that changed boot state is a change', () => {
  const before = CompanionScreens().from({
    watch: { available: true, udid: 'W-1', name: 'Watch', state: 'Shutdown' },
  });
  const after = CompanionScreens().from({
    watch: { available: true, udid: 'W-1', name: 'Watch', state: 'Booted' },
  });
  assert.ok(!before.sameAs(after));
});

// Resizing the attached display changes what the pane should draw.
test('a display that changed size is a change', () => {
  const before = CompanionScreens().from({
    external: { available: true, width: 800, height: 480 },
  });
  const after = CompanionScreens().from({
    external: { available: true, width: 1280, height: 720 },
  });
  assert.ok(!before.sameAs(after));
});

test('comparing against nothing is a change, not a crash', () => {
  const screens = CompanionScreens().from({ external: { available: true, width: 800, height: 480 } });
  assert.ok(!screens.sameAs(null));
  assert.ok(!screens.sameAs(undefined));
});
