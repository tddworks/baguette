import test from 'node:test';
import assert from 'node:assert/strict';
import { ScreenPieces } from '../../../../Sources/Baguette/Resources/Web/baguette/gestures/screen-pieces.js';

// The server names where the lit screen lands in the rendered frame:
// one quad for a phone, or — for a foldable, whose unfolded screen bends
// at the hinge — flat pieces, each carrying the part of the framebuffer
// it shows. A click maps through whichever piece it lands on, straight
// into framebuffer space.

test('should make a plain screen quad one piece showing the whole buffer', () => {
  const pieces = ScreenPieces.fromMessage({
    type: 'screen_quad', corners: [[0.1, 0.2], [0.9, 0.2], [0.9, 0.8], [0.1, 0.8]],
  });
  assert.equal(pieces.length, 1);
  const hit = pieces.locate(0.5, 0.5);
  assert.ok(hit.inside);
  assert.ok(Math.abs(hit.u - 0.5) < 1e-6 && Math.abs(hit.v - 0.5) < 1e-6);
});

test('should map a click on a piece into that piece\'s part of the buffer', () => {
  const pieces = ScreenPieces.fromMessage({
    type: 'screen_quad',
    pieces: [
      { corners: [[0.1, 0.2], [0.5, 0.2], [0.5, 0.8], [0.1, 0.8]], u: [0, 1], v: [0.5, 1] },
      { corners: [[0.5, 0.2], [0.9, 0.2], [0.9, 0.8], [0.5, 0.8]], u: [0, 1], v: [0, 0.5] },
    ],
  });
  assert.equal(pieces.length, 2);
  // Centre of the first piece: u 0.5 of the buffer, v halfway through [0.5, 1].
  const first = pieces.locate(0.3, 0.5);
  assert.ok(first.inside);
  assert.ok(Math.abs(first.u - 0.5) < 1e-6 && Math.abs(first.v - 0.75) < 1e-6);
  const second = pieces.locate(0.7, 0.35);
  assert.ok(second.inside);
  assert.ok(Math.abs(second.u - 0.5) < 1e-6 && Math.abs(second.v - 0.125) < 1e-6);
});

test('should place a click on no piece outside, and read a malformed message as empty', () => {
  const pieces = ScreenPieces.fromMessage({
    type: 'screen_quad',
    pieces: [{ corners: [[0.1, 0.2], [0.5, 0.2], [0.5, 0.8], [0.1, 0.8]], u: [0, 1], v: [0.5, 1] }],
  });
  assert.equal(pieces.locate(0.9, 0.9).inside, false);
  assert.equal(ScreenPieces.fromMessage({ type: 'screen_quad' }).length, 0);
  assert.equal(ScreenPieces.fromMessage(null).length, 0);
});
