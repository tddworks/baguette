import test from 'node:test';
import assert from 'node:assert/strict';
import { GestureEnvelope } from '../../../../Sources/Baguette/Resources/Web/baguette/gestures/gesture-envelope.js';

test('should tap for 50 ms beside the screen size by default', () => {
  const GE = GestureEnvelope;
  const envelope = GE.tap({ x: 10, y: 20 }, { width: 393, height: 852 });
  assert.deepEqual(envelope, { type: 'tap', x: 10, y: 20, duration: 0.05, width: 393, height: 852 });
});

test('should tap for the duration the caller names', () => {
  const GE = GestureEnvelope;
  const envelope = GE.tap({ x: 10, y: 20, duration: 0.2 }, { width: 393, height: 852 });
  assert.equal(envelope.duration, 0.2);
});

test('should send a tap with no edge unless the caller names one', () => {
  const GE = GestureEnvelope;
  const envelope = GE.tap({ x: 10, y: 20 }, { width: 393, height: 852 });
  assert.equal('edge' in envelope, false);
});

test('should tag a tap with the edge the caller names', () => {
  const GE = GestureEnvelope;
  const envelope = GE.tap({ x: 742, y: 44, edge: 'top' }, { width: 800, height: 480 });
  assert.equal(envelope.edge, 'top');
});

test('should pass on a bogus tap edge so the server rejects it', () => {
  const GE = GestureEnvelope;
  assert.equal(GE.tap({ x: 10, y: 20, edge: '' }, { width: 393, height: 852 }).edge, '');
});

test('should send a tap with no edge when its edge is null or undefined', () => {
  const GE = GestureEnvelope;
  const size = { width: 393, height: 852 };
  assert.equal('edge' in GE.tap({ x: 10, y: 20, edge: null }, size), false);
  assert.equal('edge' in GE.tap({ x: 10, y: 20, edge: undefined }, size), false);
});

test('should swipe for 250 ms from start to end by default', () => {
  const GE = GestureEnvelope;
  const envelope = GE.swipe({ from: { x: 1, y: 2 }, to: { x: 3, y: 4 } }, { width: 100, height: 200 });
  assert.deepEqual(envelope, {
    type: 'swipe', startX: 1, startY: 2, endX: 3, endY: 4, duration: 0.25, width: 100, height: 200,
  });
});

test('should swipe for the duration the caller names', () => {
  const GE = GestureEnvelope;
  const envelope = GE.swipe(
      { from: { x: 1, y: 2 }, to: { x: 3, y: 4 }, duration: 0.5 }, { width: 100, height: 200 }
  );
  assert.equal(envelope.duration, 0.5);
});

test('should send one finger as touch1 with no edge by default', () => {
  const GE = GestureEnvelope;
  const envelope = GE.touch('down', [{ x: 5, y: 6 }], null, { width: 100, height: 200 });
  assert.deepEqual(envelope, { type: 'touch1-down', x: 5, y: 6, width: 100, height: 200 });
});

test('should tag a one-finger touch with the edge the caller names', () => {
  const GE = GestureEnvelope;
  const envelope = GE.touch('move', [{ x: 5, y: 6 }], { edge: 'bottom' }, { width: 100, height: 200 });
  assert.equal(envelope.edge, 'bottom');
});

test('should pass on a bogus touch edge so the server rejects it', () => {
  const GE = GestureEnvelope;
  const envelope = GE.touch('down', [{ x: 5, y: 6 }], { edge: '' }, { width: 100, height: 200 });
  assert.equal(envelope.edge, '');
});

test('should send a one-finger touch with no edge when its edge is null', () => {
  const GE = GestureEnvelope;
  const envelope = GE.touch('down', [{ x: 5, y: 6 }], { edge: null }, { width: 100, height: 200 });
  assert.equal('edge' in envelope, false);
});

test('should send two fingers as touch2 carrying both points', () => {
  const GE = GestureEnvelope;
  const envelope = GE.touch(
      'up', [{ x: 1, y: 2 }, { x: 3, y: 4 }], null, { width: 100, height: 200 }
  );
  assert.deepEqual(envelope, {
    type: 'touch2-up', x1: 1, y1: 2, x2: 3, y2: 4, width: 100, height: 200,
  });
});

test('should send nothing for no fingers or more than two', () => {
  const GE = GestureEnvelope;
  assert.equal(GE.touch('down', [], null, { width: 1, height: 1 }), null);
  assert.equal(
      GE.touch('down', [{ x: 0, y: 0 }, { x: 1, y: 1 }, { x: 2, y: 2 }], null, { width: 1, height: 1 }),
      null
  );
});

test('should send a hover as where the pointer is, beside the screen size', () => {
  assert.deepEqual(GestureEnvelope.hover({ x: 12.5, y: 40 }, { width: 603, height: 1311 }),
    { type: 'hover', x: 12.5, y: 40, width: 603, height: 1311 });
});
