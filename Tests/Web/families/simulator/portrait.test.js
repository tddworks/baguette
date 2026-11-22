import test from 'node:test';
import assert from 'node:assert/strict';
import { toPortrait } from '../../../../Sources/Baguette/Resources/Web/families/simulator/internal/portrait.js';

// A turned simulator is drawn rotated, so the page's input arrives in the
// frame the user sees; iOS takes portrait coordinates. Each envelope is turned
// back before it's sent, its edge flag too, or the home gesture never fires.

const tap = { type: 'tap', x: 100, y: 50, width: 400, height: 800 };

test('should send portrait input as it is', () => {
  assert.deepEqual(toPortrait(tap, 'portrait'), tap);
});

test('should turn a tap back from each orientation the device is drawn in', () => {
  assert.deepEqual(toPortrait(tap, 'landscape-right'), { ...tap, x: 400 * (1 - 50 / 800), y: 800 * (100 / 400) });
  assert.deepEqual(toPortrait(tap, 'portrait-upside-down'), { ...tap, x: 300, y: 750 });
  assert.deepEqual(toPortrait(tap, 'landscape-left'), { ...tap, x: 400 * (50 / 800), y: 800 * (1 - 100 / 400) });
});

test('should turn both ends of a swipe and both fingers of a pinch', () => {
  const swipe = { type: 'swipe', startX: 0, startY: 0, endX: 400, endY: 800, width: 400, height: 800 };
  assert.deepEqual(toPortrait(swipe, 'portrait-upside-down'), { ...swipe, startX: 400, startY: 800, endX: 0, endY: 0 });
  const pinch = { type: 'touch2-move', x1: 0, y1: 0, x2: 400, y2: 800, width: 400, height: 800 };
  assert.deepEqual(toPortrait(pinch, 'portrait-upside-down'), { ...pinch, x1: 400, y1: 800, x2: 0, y2: 0 });
});

test('should flag a swipe from the bottom as the physical edge it comes from', () => {
  const from = (orientation) => toPortrait({ type: 'touch1-down', x: 0, y: 0, width: 1, height: 1, edge: 'bottom' }, orientation).edge;
  assert.equal(from('portrait'), 'bottom');
  assert.equal(from('landscape-left'), 'right');
  assert.equal(from('portrait-upside-down'), 'right');
  assert.equal(from('landscape-right'), 'top');
});

test('should leave anything without coordinates as it is', () => {
  const key = { type: 'key', code: 'KeyA' };
  assert.equal(toPortrait(key, 'landscape-left'), key);
  assert.equal(toPortrait(null, 'landscape-left'), null);
});
