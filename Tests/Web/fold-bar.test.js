'use strict';

// FoldBar — Device Hub's pose bar: three poses and a hinge slider.

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { loadBrowserModule } = require('./helpers/load-browser-module.js');

const MODULE_PATH = path.join(
  __dirname, '..', '..', 'Sources', 'Baguette', 'Resources', 'Web',
  'baguette', 'hinge', 'fold-bar.js'
);

function makeBar(opts) {
  const { Baguette } = loadBrowserModule(MODULE_PATH);
  const sent = [];
  const pending = [];
  const bar = new Baguette.FoldBar(Object.assign({
    send: (payload) => sent.push(payload),
    schedule: (fn) => pending.push(fn),
  }, opts || {}));
  const flush = () => { while (pending.length) pending.shift()(); };
  return { bar, sent, flush, FoldBar: Baguette.FoldBar };
}

test('the pose nearest the hinge is the one that lights', () => {
  const { FoldBar } = makeBar();
  assert.equal(FoldBar.nearest(3), 'shut');
  assert.equal(FoldBar.nearest(60), 'shut');
  assert.equal(FoldBar.nearest(100), 'open');
  assert.equal(FoldBar.nearest(170), 'flat');
});

test('picking a pose sweeps the hinge there', () => {
  const { bar, sent } = makeBar();
  bar.pick('open');
  bar.pick('flat');
  assert.deepEqual(sent, [
    { type: 'set_pose', hingeDegrees: 130 },
    { type: 'set_pose', hingeDegrees: 180 },
  ]);
});

test('the hinge goes under the thumb as it is dragged, not only on release', () => {
  const { bar, sent, flush } = makeBar();
  bar.drag(72);
  flush();
  bar.drag(72);
  flush();
  bar.release(90);
  assert.deepEqual(sent, [
    { type: 'set_pose', hingeDegrees: 72, duration: 0 },
    { type: 'set_pose', hingeDegrees: 90, duration: 0 },
  ]);
});

test('the slider follows the hinge unless it is held', () => {
  const { bar } = makeBar();
  bar.show(130);
  assert.equal(bar.active, 'open');
  assert.equal(bar.sliderValue, 130);
  bar.drag(40);
  bar.show(3.4);
  assert.equal(bar.active, 'shut');
  assert.equal(bar.sliderValue, 40);
  bar.release(40);
  bar.show(3.4);
  assert.equal(bar.sliderValue, 3);
});
