import test from 'node:test';
import assert from 'node:assert/strict';
import { CaptureSize } from '../../../Sources/Baguette/Resources/Web/capture/capture-size.js';

// ── the preset catalogue ─────────────────────────────────────

test('should list native, then the App Store sizes, then the ratios', () => {
  const ids = CaptureSize.presets().map((p) => p.id);
  assert.deepEqual(ids, [
    'native',
    'appstore-6.9', 'appstore-6.5', 'appstore-ipad-13',
    'square', '16:9', '9:16', '4:3', '4:5',
  ]);
});

test('should give every preset a label for the picker', () => {
  for (const preset of CaptureSize.presets()) {
    assert.equal(typeof preset.label, 'string');
    assert.ok(preset.label.length > 0, `${preset.id} has no label`);
  }
});

// ── parsing ──────────────────────────────────────────────────

test('should parse a preset id', () => {
  assert.equal(CaptureSize.parse('appstore-6.9').id, 'appstore-6.9');
});

test('should parse a literal WxH into a custom size', () => {
  const size = CaptureSize.parse('1920x1080');
  assert.equal(size.id, 'custom');
  assert.deepEqual(size.resolve(400, 800), { width: 1920, height: 1080 });
});

test('should parse an unlisted W:H ratio', () => {
  const size = CaptureSize.parse('3:2');
  assert.deepEqual(size.resolve(600, 600), { width: 900, height: 600 });
});

test('should reject garbage rather than guess', () => {
  const CS = CaptureSize;
  assert.equal(CS.parse('appstore'), null);
  assert.equal(CS.parse('1920x'), null);
  assert.equal(CS.parse('0x100'), null);
  assert.equal(CS.parse(''), null);
  assert.equal(CS.parse(null), null);
});

// ── resolution ───────────────────────────────────────────────

test('should resolve native to the source dimensions untouched', () => {
  assert.deepEqual(
    CaptureSize.parse('native').resolve(1290, 2796),
    { width: 1290, height: 2796 }
  );
});

test('should resolve an App Store preset to its fixed pixel size', () => {
  assert.deepEqual(
    CaptureSize.parse('appstore-6.9').resolve(400, 800),
    { width: 1290, height: 2796 }
  );
});

// A ratio preset never downscales the source: it grows the short axis so
// the source still fits at 1:1. A portrait phone asked for `square` grows
// sideways to the phone's own height.
test('should grow the narrow axis of a portrait source to a square', () => {
  assert.deepEqual(
    CaptureSize.parse('square').resolve(1290, 2796),
    { width: 2796, height: 2796 }
  );
});

test('should grow a portrait source sideways to 16:9', () => {
  assert.deepEqual(
    CaptureSize.parse('16:9').resolve(1290, 2796),
    { width: 4971, height: 2796 }
  );
});

test('should widen a source narrower than 9:16', () => {
  // 1290/2796 ≈ 0.461 is narrower than 9/16 = 0.5625, so height binds and
  // the canvas widens to 2796 × 9/16 — the source still fits at 1:1.
  assert.deepEqual(
    CaptureSize.parse('9:16').resolve(1290, 2796),
    { width: 1573, height: 2796 }
  );
});

// ── placement ────────────────────────────────────────────────

test('should letterbox and centre the source when contained', () => {
  const plan = CaptureSize.parse('square').plan(1000, 2000, 'contain');
  assert.deepEqual(plan, {
    width: 2000, height: 2000,
    drawX: 500, drawY: 0, drawW: 1000, drawH: 2000,
    sourceWidth: 1000, sourceHeight: 2000,
  });
});

test('should fill the canvas and crop the overflow when covering', () => {
  const plan = CaptureSize.parse('square').plan(1000, 2000, 'cover');
  assert.deepEqual(plan, {
    width: 2000, height: 2000,
    drawX: 0, drawY: -1000, drawW: 2000, drawH: 4000,
    sourceWidth: 1000, sourceHeight: 2000,
  });
});

test('should distort the source to fill the canvas when stretched', () => {
  const plan = CaptureSize.parse('1920x1080').plan(1000, 2000, 'stretch');
  assert.deepEqual(plan, {
    width: 1920, height: 1080,
    drawX: 0, drawY: 0, drawW: 1920, drawH: 1080,
    sourceWidth: 1000, sourceHeight: 2000,
  });
});

test('should place native untouched whatever the fit', () => {
  for (const fit of ['contain', 'cover', 'stretch']) {
    assert.deepEqual(
      CaptureSize.parse('native').plan(1290, 2796, fit),
      {
        width: 1290, height: 2796, drawX: 0, drawY: 0, drawW: 1290, drawH: 2796,
        sourceWidth: 1290, sourceHeight: 2796,
      },
      `fit=${fit}`
    );
  }
});

test('should fall back to contain when the fit is unknown', () => {
  assert.deepEqual(
    CaptureSize.parse('square').plan(1000, 2000, 'wat'),
    CaptureSize.parse('square').plan(1000, 2000, 'contain')
  );
});

test('should plan nothing for a zero-sized source', () => {
  const plan = CaptureSize.parse('square').plan(0, 0, 'contain');
  assert.equal(plan.width, 0);
  assert.equal(plan.height, 0);
  assert.ok(Number.isFinite(plan.drawW));
  assert.equal(plan.sourceWidth, 0);
});

// The Swift `CaptureSize` has to place a frame on the same pixel as this
// one. Swift's `Double.rounded()` rounds half away from zero where
// `Math.round` rounds half up, so they only disagree on a negative half —
// i.e. a `cover` draw origin. `CaptureSizeTests.swift` asserts these
// same numbers; if you change one, change both.
test('should round a cover overflow the way the Swift side does', () => {
  const plan = CaptureSize.parse('square').plan(1000, 2001, 'cover');
  assert.equal(plan.drawY, -1001);
  assert.equal(plan.width, 2001);
  assert.equal(plan.drawH, 4004);
});

// ── round-tripping through the wire / storage ────────────────

test('should parse back every spec it writes', () => {
  const CS = CaptureSize;
  for (const preset of CS.presets()) {
    assert.equal(CS.parse(preset.spec).id, preset.id, preset.id);
  }
  assert.equal(CS.parse(CS.parse('1920x1080').spec).spec, '1920x1080');
});

// ── the terse spelling the toolbar chip wears ────────────────

// The chip used to render `label`, so it was "Native" (54px) one
// moment and "App Store iPad 13″" (132px) the next — the one control
// whose width the user changes by using it, in a toolbar that is a
// single row of fixed-size controls. `code` is the same choice in at
// most four tabular characters, so the chip can hold one width.

test('should give every preset a terse code for the chip', () => {
  const catalogue = CaptureSize;
  assert.deepEqual(catalogue.presets().map((p) => p.code), [
    'Auto', '6.9″', '6.5″', '13″', '1:1', '16:9', '9:16', '4:3', '4:5',
  ]);
});

test('should use an ad-hoc ratio as its own code', () => {
  assert.equal(CaptureSize.parse('3:2').code, '3:2');
});

// A literal pixel spec has no short spelling — "1920x1080" is wider
// than the label it replaced. The chip says Custom and the popover's
// resolved dimensions say which.
test('should read a literal pixel spec as Custom on the chip', () => {
  assert.equal(CaptureSize.parse('1920x1080').code, 'Custom');
});

// ── the aspect the chip draws ────────────────────────────────

test('should report a ratio exactly, not a rounded resolve', () => {
  assert.equal(CaptureSize.parse('16:9').aspect(), 16 / 9);
});

test('should report a fixed size by its own pixel aspect', () => {
  assert.equal(CaptureSize.named('appstore-6.9').aspect(), 1290 / 2796);
});

// Native has no shape of its own — it is whatever the source is — so
// the chip draws nothing rather than guessing a rectangle.
test('should report no aspect for native', () => {
  assert.equal(CaptureSize.named('native').aspect(), null);
});
