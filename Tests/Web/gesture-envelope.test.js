'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { loadBrowserModule } = require('./helpers/load-browser-module.js');

const MODULE_PATH = path.join(
  __dirname, '..', '..', 'Sources', 'Baguette', 'Resources', 'Web',
  'baguette', 'gestures', 'gesture-envelope.js'
);

function GestureEnvelope() {
  return loadBrowserModule(MODULE_PATH).Baguette._GestureEnvelope;
}

test('tap defaults duration to 50ms and carries the screen size', () => {
  const GE = GestureEnvelope();
  const envelope = GE.tap({ x: 10, y: 20 }, { width: 393, height: 852 });
  assert.deepEqual(envelope, { type: 'tap', x: 10, y: 20, duration: 0.05, width: 393, height: 852 });
});

test('tap honors an explicit duration', () => {
  const GE = GestureEnvelope();
  const envelope = GE.tap({ x: 10, y: 20, duration: 0.2 }, { width: 393, height: 852 });
  assert.equal(envelope.duration, 0.2);
});

test('tap omits the edge key unless the caller names one', () => {
  const GE = GestureEnvelope();
  const envelope = GE.tap({ x: 10, y: 20 }, { width: 393, height: 852 });
  assert.equal('edge' in envelope, false);
});

test('tap tags the edge when the caller supplies one', () => {
  const GE = GestureEnvelope();
  const envelope = GE.tap({ x: 742, y: 44, edge: 'top' }, { width: 800, height: 480 });
  assert.equal(envelope.edge, 'top');
});

test('tap forwards a supplied-but-bogus edge so the server rejects it', () => {
  const GE = GestureEnvelope();
  assert.equal(GE.tap({ x: 10, y: 20, edge: '' }, { width: 393, height: 852 }).edge, '');
});

test('tap treats null and undefined edges as no edge at all', () => {
  const GE = GestureEnvelope();
  const size = { width: 393, height: 852 };
  assert.equal('edge' in GE.tap({ x: 10, y: 20, edge: null }, size), false);
  assert.equal('edge' in GE.tap({ x: 10, y: 20, edge: undefined }, size), false);
});

test('swipe defaults duration to 250ms and maps from/to onto startX/Y, endX/Y', () => {
  const GE = GestureEnvelope();
  const envelope = GE.swipe({ from: { x: 1, y: 2 }, to: { x: 3, y: 4 } }, { width: 100, height: 200 });
  assert.deepEqual(envelope, {
    type: 'swipe', startX: 1, startY: 2, endX: 3, endY: 4, duration: 0.25, width: 100, height: 200,
  });
});

test('swipe honors an explicit duration', () => {
  const GE = GestureEnvelope();
  const envelope = GE.swipe(
      { from: { x: 1, y: 2 }, to: { x: 3, y: 4 }, duration: 0.5 }, { width: 100, height: 200 }
  );
  assert.equal(envelope.duration, 0.5);
});

test('touch with one finger builds a touch1 envelope without an edge key by default', () => {
  const GE = GestureEnvelope();
  const envelope = GE.touch('down', [{ x: 5, y: 6 }], null, { width: 100, height: 200 });
  assert.deepEqual(envelope, { type: 'touch1-down', x: 5, y: 6, width: 100, height: 200 });
});

test('touch with one finger tags the edge when the caller supplies one', () => {
  const GE = GestureEnvelope();
  const envelope = GE.touch('move', [{ x: 5, y: 6 }], { edge: 'bottom' }, { width: 100, height: 200 });
  assert.equal(envelope.edge, 'bottom');
});

test('touch with one finger forwards a supplied-but-bogus edge so the server rejects it', () => {
  const GE = GestureEnvelope();
  const envelope = GE.touch('down', [{ x: 5, y: 6 }], { edge: '' }, { width: 100, height: 200 });
  assert.equal(envelope.edge, '');
});

test('touch with one finger treats a null edge as no edge at all', () => {
  const GE = GestureEnvelope();
  const envelope = GE.touch('down', [{ x: 5, y: 6 }], { edge: null }, { width: 100, height: 200 });
  assert.equal('edge' in envelope, false);
});

test('touch with two fingers builds a touch2 envelope carrying both points', () => {
  const GE = GestureEnvelope();
  const envelope = GE.touch(
      'up', [{ x: 1, y: 2 }, { x: 3, y: 4 }], null, { width: 100, height: 200 }
  );
  assert.deepEqual(envelope, {
    type: 'touch2-up', x1: 1, y1: 2, x2: 3, y2: 4, width: 100, height: 200,
  });
});

test('touch with zero or three-plus fingers builds nothing', () => {
  const GE = GestureEnvelope();
  assert.equal(GE.touch('down', [], null, { width: 1, height: 1 }), null);
  assert.equal(
      GE.touch('down', [{ x: 0, y: 0 }, { x: 1, y: 1 }, { x: 2, y: 2 }], null, { width: 1, height: 1 }),
      null
  );
});

test('should send a hover as where the pointer is, beside the screen size', () => {
  assert.deepEqual(GestureEnvelope().hover({ x: 12.5, y: 40 }, { width: 603, height: 1311 }),
    { type: 'hover', x: 12.5, y: 40, width: 603, height: 1311 });
});
