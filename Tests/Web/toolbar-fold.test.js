'use strict';

// ToolbarFold decides WHAT the focus toolbar gives up when the row is
// too narrow. It owns no DOM: the caller hands it a `fits` callback
// that renders a candidate state and reports whether it fits, and gets
// back the first state that did. That split is what makes the
// arithmetic testable — the rendering stays integration-only, same bar
// as page/device-page.js itself.

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { loadBrowserModules } = require('./helpers/load-browser-module.js');

const WEB = path.join(
  __dirname, '..', '..', 'Sources', 'Baguette', 'Resources', 'Web', 'toolbar'
);

function ToolbarFold() {
  return loadBrowserModules([path.join(WEB, 'toolbar-fold.js')])
    .Baguette._ToolbarFold;
}

// Array order is where a cluster SITS; `fold` is how hard it holds on.
// Deliberately declared out of fold order here — a cluster that
// survives a narrowing must not also move, so the two orders have to
// stay independent.
const CLUSTERS = [
  { id: 'nav' },
  { id: 'stream',   fold: 3 },
  { id: 'view' },
  { id: 'control',  fold: 4 },
  { id: 'simulate', fold: 1 },
  { id: 'inspect',  fold: 2 },
  { id: 'capture' },
];

/** A `fits` stub that refuses the first `n` candidates, then accepts. */
function refusing(n) {
  const seen = [];
  const fits = (state) => {
    seen.push({
      folded: state.folded.slice(), merged: state.merged, tight: state.tight,
    });
    return seen.length > n;
  };
  fits.seen = seen;
  return fits;
}

// ── nothing to do ────────────────────────────────────────────────

test('a row that already fits folds nothing', () => {
  const plan = new (ToolbarFold())(CLUSTERS).plan(refusing(0));
  assert.deepEqual(plan, { folded: [], merged: false, tight: false });
});

// ── folding, in fold order ───────────────────────────────────────

test('the worst-ranked cluster folds first', () => {
  const plan = new (ToolbarFold())(CLUSTERS).plan(refusing(1));
  assert.deepEqual(plan.folded, ['simulate']);
});

test('folding continues down the fold order, not the array order', () => {
  const plan = new (ToolbarFold())(CLUSTERS).plan(refusing(3));
  assert.deepEqual(plan.folded, ['simulate', 'inspect', 'stream']);
});

test('a cluster with no fold rank never folds', () => {
  const plan = new (ToolbarFold())(CLUSTERS).plan(refusing(99));
  assert.deepEqual(plan.folded, ['simulate', 'inspect', 'stream', 'control']);
});

// ── merging is a last resort ─────────────────────────────────────

// Separate cluster buttons keep their meaning — you can go straight to
// Simulate — so they survive until even they will not fit.
test('four folded clusters stay four buttons while they fit', () => {
  const plan = new (ToolbarFold())(CLUSTERS).plan(refusing(4));
  assert.equal(plan.merged, false);
  assert.equal(plan.folded.length, 4);
});

test('merging happens only after every cluster has folded', () => {
  const fits = refusing(5);
  const plan = new (ToolbarFold())(CLUSTERS).plan(fits);
  assert.equal(plan.merged, true);
  assert.deepEqual(fits.seen[5], {
    folded: ['simulate', 'inspect', 'stream', 'control'],
    merged: true, tight: false,
  });
});

// One folded cluster IS its own menu already; merging it would swap a
// named button for an anonymous one and save nothing.
test('a single folded cluster is never merged', () => {
  const only = [{ id: 'nav' }, { id: 'simulate', fold: 1 }, { id: 'capture' }];
  const plan = new (ToolbarFold())(only).plan(refusing(99));
  assert.deepEqual(plan, { folded: ['simulate'], merged: false, tight: true });
});

// ── the device name is the last thing to give ────────────────────

test('the name truncates only when nothing else is left to fold', () => {
  const plan = new (ToolbarFold())(CLUSTERS).plan(refusing(99));
  assert.equal(plan.tight, true);
  assert.equal(plan.merged, true);
});

test('a row that fits after merging never goes tight', () => {
  assert.equal(new (ToolbarFold())(CLUSTERS).plan(refusing(5)).tight, false);
});

// ── the caller sees every candidate, in order ────────────────────

test('each candidate is offered exactly once, widest first', () => {
  const fits = refusing(99);
  new (ToolbarFold())(CLUSTERS).plan(fits);
  assert.deepEqual(fits.seen.map((s) => s.folded.length), [0, 1, 2, 3, 4, 4, 4]);
  assert.deepEqual(fits.seen.map((s) => s.merged), [false, false, false, false, false, true, true]);
  assert.deepEqual(fits.seen.map((s) => s.tight), [false, false, false, false, false, false, true]);
});

// ── the fold order is readable on its own ────────────────────────

test('reports its fold order so a caller can explain itself', () => {
  assert.deepEqual(new (ToolbarFold())(CLUSTERS).order,
    ['simulate', 'inspect', 'stream', 'control']);
});
