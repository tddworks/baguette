import test from 'node:test';
import assert from 'node:assert/strict';
import { EdgeBands } from '../../../../Sources/Baguette/Resources/Web/baguette/gestures/edge-bands.js';

test('should name a point in the bottom hot zone "bottom" in portrait', () => {
  const EB = EdgeBands;
  const bands = new EB(0.93, 0.07);
  assert.equal(bands.classify({ xNorm: 0.5, yNorm: 0.95 }, 'portrait'), 'bottom');
});

test('should name a point in the top hot zone "top" in portrait', () => {
  const EB = EdgeBands;
  const bands = new EB(0.93, 0.07);
  assert.equal(bands.classify({ xNorm: 0.5, yNorm: 0.02 }, 'portrait'), 'top');
});

test('should name no edge for a point outside both hot zones', () => {
  const EB = EdgeBands;
  const bands = new EB(0.93, 0.07);
  assert.equal(bands.classify({ xNorm: 0.5, yNorm: 0.5 }, 'portrait'), null);
});

test('should turn the hot zones onto the visual left and right when portrait upside down', () => {
  const EB = EdgeBands;
  const bands = new EB(0.93, 0.07);
  // Physical home-indicator edge is still "bottom" of the device, which
  // is visual-LEFT when the device is rendered upside down.
  assert.equal(bands.classify({ xNorm: 0.02, yNorm: 0.5 }, 'portrait-upside-down'), 'bottom');
  assert.equal(bands.classify({ xNorm: 0.98, yNorm: 0.5 }, 'portrait-upside-down'), 'top');
  assert.equal(bands.classify({ xNorm: 0.5, yNorm: 0.02 }, 'portrait-upside-down'), null);
});

test('should use the caller\'s own thresholds (touch\'s wider bands)', () => {
  const EB = EdgeBands;
  const touchBands = new EB(0.85, 0.15);
  assert.equal(touchBands.classify({ xNorm: 0.5, yNorm: 0.88 }, 'portrait'), 'bottom');
  // Same point would NOT be in the mouse's narrower band.
  const mouseBands = new EB(0.93, 0.07);
  assert.equal(mouseBands.classify({ xNorm: 0.5, yNorm: 0.88 }, 'portrait'), null);
});
