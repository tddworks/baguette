import test from 'node:test';
import assert from 'node:assert/strict';
import { HandheldButton } from '../../../Sources/Baguette/Resources/Web/handheld/handheld-button.js';

const VIEW = { width: 400, height: 800 };
const NO_INSETS = { top: 0, bottom: 0, left: 0, right: 0 };
const SIZE = 56;
const MARGIN = 8;

// --- rest: where a dropped button settles -----------------------------

test('should settle against the left edge when dropped on the left half', () => {
  const spot = HandheldButton.rest({ x: 120, y: 400, viewport: VIEW, size: SIZE });
  assert.equal(spot.side, 'left');
});

test('should settle against the right edge when dropped on the right half', () => {
  const spot = HandheldButton.rest({ x: 300, y: 400, viewport: VIEW, size: SIZE });
  assert.equal(spot.side, 'right');
});

test('should remember the height it was dropped at as a share of the view', () => {
  // Centre at y=400 in an 800 view, so the share of the travel is ½.
  const spot = HandheldButton.rest({ x: 300, y: 400, viewport: VIEW, size: SIZE });
  assert.ok(Math.abs(spot.yNorm - 0.5) < 1e-9);
});

test('should keep the remembered height within the view when dropped past an edge', () => {
  const B = HandheldButton;
  assert.equal(B.rest({ x: 300, y: -50, viewport: VIEW, size: SIZE }).yNorm, 0);
  assert.equal(B.rest({ x: 300, y: 900, viewport: VIEW, size: SIZE }).yNorm, 1);
});

// --- place: where a remembered spot is drawn --------------------------

test('should sit a margin in from the right edge when resting on the right', () => {
  const at = HandheldButton.place({
    side: 'right', yNorm: 0, viewport: VIEW, size: SIZE, margin: MARGIN, insets: NO_INSETS,
  });
  assert.equal(at.left, VIEW.width - SIZE - MARGIN);
  assert.equal(at.top, MARGIN);
});

test('should sit a margin in from the left edge when resting on the left', () => {
  const at = HandheldButton.place({
    side: 'left', yNorm: 1, viewport: VIEW, size: SIZE, margin: MARGIN, insets: NO_INSETS,
  });
  assert.equal(at.left, MARGIN);
  assert.equal(at.top, VIEW.height - SIZE - MARGIN);
});

test('should stay clear of the status bar and home indicator when the phone reserves them', () => {
  const B = HandheldButton;
  const insets = { top: 59, bottom: 34, left: 0, right: 0 };
  const top = B.place({ side: 'left', yNorm: 0, viewport: VIEW, size: SIZE, margin: MARGIN, insets });
  const bottom = B.place({ side: 'left', yNorm: 1, viewport: VIEW, size: SIZE, margin: MARGIN, insets });
  assert.equal(top.top, 59 + MARGIN);
  assert.equal(bottom.top, VIEW.height - 34 - SIZE - MARGIN);
});

test('should come back to the same spot after the view is resized', () => {
  const B = HandheldButton;
  const spot = B.rest({ x: 380, y: 600, viewport: VIEW, size: SIZE });
  const wide = { width: 800, height: 400 };
  const at = B.place({ ...spot, viewport: wide, size: SIZE, margin: MARGIN, insets: NO_INSETS });
  assert.equal(at.left, wide.width - SIZE - MARGIN);
  assert.ok(at.top >= MARGIN && at.top <= wide.height - SIZE - MARGIN);
});

// --- isTap ------------------------------------------------------------

test('should open the menu when the finger lifts where it landed', () => {
  assert.equal(HandheldButton.isTap({ dx: 3, dy: -4 }), true);
});

test('should move the button instead of opening the menu when the finger travels', () => {
  assert.equal(HandheldButton.isTap({ dx: 0, dy: 24 }), false);
});
