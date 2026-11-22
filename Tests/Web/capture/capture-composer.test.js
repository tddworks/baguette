import test from 'node:test';
import assert from 'node:assert/strict';
import { CaptureSize } from '../../../Sources/Baguette/Resources/Web/capture/capture-size.js';
import { CaptureComposer } from '../../../Sources/Baguette/Resources/Web/capture/capture-composer.js';

function modules() {
  return { CaptureSize, CaptureComposer };
}

// A canvas 2D context stand-in that tracks the current transform and
// records every paint in FINAL canvas pixels — the same state a real
// canvas would end up in, just readable.
function fakeCtx() {
  const ops = [];
  let m = { x: 0, y: 0, sx: 1, sy: 1 };
  const stack = [];
  return {
    ops,
    canvas: { width: 0, height: 0 },
    fillStyle: '',
    imageSmoothingEnabled: false,
    imageSmoothingQuality: '',
    save() { stack.push({ ...m }); },
    restore() { m = stack.pop() || m; },
    translate(x, y) { m.x += x * m.sx; m.y += y * m.sy; },
    scale(sx, sy) { m.sx *= sx; m.sy *= sy; },
    clearRect(x, y, w, h) { ops.push(['clear', x, y, w, h]); },
    fillRect(x, y, w, h) {
      ops.push(['fill', this.fillStyle, m.x + x * m.sx, m.y + y * m.sy,
        w * m.sx, h * m.sy]);
    },
    drawImage(img, x, y, w, h) {
      ops.push(['draw', img.tag, m.x + x * m.sx, m.y + y * m.sy,
        w * m.sx, h * m.sy]);
    },
    beginPath() { ops.push(['beginPath']); },
    moveTo() {}, lineTo() {}, quadraticCurveTo() {}, closePath() {},
    clip() { ops.push(['clip']); },
    arc() {}, stroke() {},
  };
}

const source = (tag, width, height) => ({ tag, width, height });

// ── background ───────────────────────────────────────────────

test('should fill the whole canvas with the background before drawing', () => {
  const { CaptureSize, CaptureComposer } = modules();
  const ctx = fakeCtx();
  const plan = CaptureSize.parse('square').plan(1000, 2000, 'contain');

  CaptureComposer.compose(ctx, plan, '#ff0000', () => {});

  assert.deepEqual(ctx.ops[0], ['clear', 0, 0, 2000, 2000]);
  assert.deepEqual(ctx.ops[1], ['fill', '#ff0000', 0, 0, 2000, 2000]);
});

test('should clear without filling when the background is transparent', () => {
  const { CaptureSize, CaptureComposer } = modules();
  const ctx = fakeCtx();
  const plan = CaptureSize.parse('square').plan(1000, 2000, 'contain');

  CaptureComposer.compose(ctx, plan, 'transparent', () => {});

  assert.deepEqual(ctx.ops, [['clear', 0, 0, 2000, 2000]]);
});

// ── placement ────────────────────────────────────────────────

// The callback paints in SOURCE coordinates; compose maps them onto the
// target canvas so no caller has to redo the letterbox arithmetic.
test('should map a paint in source coordinates onto the letterboxed rect', () => {
  const { CaptureSize, CaptureComposer } = modules();
  const ctx = fakeCtx();
  const plan = CaptureSize.parse('square').plan(1000, 2000, 'contain');

  CaptureComposer.compose(ctx, plan, 'transparent', (c) => {
    c.drawImage(source('screen', 1000, 2000), 0, 0, 1000, 2000);
  });

  assert.deepEqual(ctx.ops[1], ['draw', 'screen', 500, 0, 1000, 2000]);
});

test('should scale the source paint up when the target is larger', () => {
  const { CaptureSize, CaptureComposer } = modules();
  const ctx = fakeCtx();
  // 1000x2000 source into a fixed 2000x4000 canvas → 2x.
  const plan = CaptureSize.parse('2000x4000').plan(1000, 2000, 'contain');

  CaptureComposer.compose(ctx, plan, 'transparent', (c) => {
    c.drawImage(source('screen', 1000, 2000), 100, 200, 400, 400);
  });

  assert.deepEqual(ctx.ops[1], ['draw', 'screen', 200, 400, 800, 800]);
});

test('should leave no transform behind for a second compose', () => {
  const { CaptureSize, CaptureComposer } = modules();
  const ctx = fakeCtx();
  const plan = CaptureSize.parse('square').plan(1000, 2000, 'contain');
  const paint = (c) => c.drawImage(source('screen', 1000, 2000), 0, 0, 1000, 2000);

  CaptureComposer.compose(ctx, plan, 'transparent', paint);
  CaptureComposer.compose(ctx, plan, 'transparent', paint);

  assert.deepEqual(ctx.ops[1], ctx.ops[3]);
});

test('should paint no source when the plan is empty', () => {
  const { CaptureSize, CaptureComposer } = modules();
  const ctx = fakeCtx();
  const plan = CaptureSize.parse('square').plan(0, 0, 'contain');
  let painted = false;

  CaptureComposer.compose(ctx, plan, 'transparent', () => { painted = true; });

  assert.equal(painted, false);
});

// ── the bezel composite ──────────────────────────────────────

const SCREEN = {
  viewport: { width: 1400, height: 2900 },
  rect: { x: 55, y: 52, width: 1290, height: 2796 },
  clipRadius: 120,
};

test('should size the composite to the bezel viewport when a frame is loaded', () => {
  const { CaptureComposer } = modules();
  assert.deepEqual(
    CaptureComposer.compositeSize({ naturalWidth: 1400 }, SCREEN, { width: 1290, height: 2796 }),
    { width: 1400, height: 2900 }
  );
});

test('should size the composite to the source canvas when there is no bezel', () => {
  const { CaptureComposer } = modules();
  assert.deepEqual(
    CaptureComposer.compositeSize(null, SCREEN, { width: 1290, height: 2796 }),
    { width: 1290, height: 2796 }
  );
});

test('should size the composite to the source canvas when the bezel has not decoded', () => {
  const { CaptureComposer } = modules();
  assert.deepEqual(
    CaptureComposer.compositeSize({ naturalWidth: 0 }, SCREEN, { width: 1290, height: 2796 }),
    { width: 1290, height: 2796 }
  );
});

// DeviceKit composites paint an opaque dark "off glass" in the screen
// cutout, meant to sit UNDER live content — so the bezel goes down first
// and the screen lands on top, clipped to the inner corner radius.
test('should paint the bezel under the clipped screen', () => {
  const { CaptureComposer } = modules();
  const ctx = fakeCtx();

  CaptureComposer.paintComposite(ctx, {
    frameImg: { tag: 'bezel', naturalWidth: 1400 },
    screen: SCREEN,
    sourceCanvas: source('screen', 1290, 2796),
  });

  assert.deepEqual(ctx.ops[0], ['draw', 'bezel', 0, 0, 1400, 2900]);
  assert.ok(ctx.ops.some((o) => o[0] === 'clip'), 'screen is clipped');
  assert.deepEqual(
    ctx.ops[ctx.ops.length - 1],
    ['draw', 'screen', 55, 52, 1290, 2796]
  );
});

test('should paint the bare screen at the origin when there is no bezel', () => {
  const { CaptureComposer } = modules();
  const ctx = fakeCtx();

  CaptureComposer.paintComposite(ctx, {
    frameImg: null,
    screen: SCREEN,
    sourceCanvas: source('screen', 1290, 2796),
  });

  assert.deepEqual(ctx.ops, [['draw', 'screen', 0, 0, 1290, 2796]]);
});

test('should hand the overlay the screen rect so dots land inside the clip', () => {
  const { CaptureComposer } = modules();
  const ctx = fakeCtx();
  let handed = null;

  CaptureComposer.paintComposite(ctx, {
    frameImg: { tag: 'bezel', naturalWidth: 1400 },
    screen: SCREEN,
    sourceCanvas: source('screen', 1290, 2796),
    onOverlay: (c, rect) => { handed = rect; },
  });

  assert.deepEqual(handed, { x: 55, y: 52, width: 1290, height: 2796 });
});

// Pressing Record (or Screenshot) before the first frame has decoded is
// ordinary: the stream may still be negotiating. The device frame is
// already loaded and is worth painting on its own — an empty source
// should cost you the screen layer, not the whole composite.
test('should still paint the bezel when the source has not decoded', () => {
  const { CaptureComposer } = modules();
  const ctx = fakeCtx();

  CaptureComposer.paintComposite(ctx, {
    frameImg: { tag: 'bezel', naturalWidth: 1400 },
    screen: SCREEN,
    sourceCanvas: source('screen', 0, 0),
  });

  assert.deepEqual(ctx.ops, [['draw', 'bezel', 0, 0, 1400, 2900]]);
});

test('should paint no overlay when there is no screen content', () => {
  const { CaptureComposer } = modules();
  const ctx = fakeCtx();
  let overlaid = false;

  CaptureComposer.paintComposite(ctx, {
    frameImg: { tag: 'bezel', naturalWidth: 1400 },
    screen: SCREEN,
    sourceCanvas: source('screen', 0, 0),
    onOverlay: () => { overlaid = true; },
  });

  assert.equal(overlaid, false);
});

test('should paint nothing when there is neither a bezel nor a decoded source', () => {
  const { CaptureComposer } = modules();
  const ctx = fakeCtx();

  CaptureComposer.paintComposite(ctx, {
    frameImg: null,
    screen: SCREEN,
    sourceCanvas: source('screen', 0, 0),
  });

  assert.deepEqual(ctx.ops, []);
});

// compositeSize already falls back to the bezel viewport, so a capture
// started before the first frame is full-size rather than 0x0.
test('should size the composite from the bezel when the source is undecoded', () => {
  const { CaptureComposer } = modules();
  assert.deepEqual(
    CaptureComposer.compositeSize({ naturalWidth: 1400 }, SCREEN, { width: 0, height: 0 }),
    { width: 1400, height: 2900 }
  );
});

// ── supersampling the composite ──────────────────────────────

// DeviceKit authors its bezels in points — an iPhone 17 Pro Max frame is
// a 474 × 990 viewport with a 438 × 954 cutout — while the live canvas
// carries the device's full 1320 × 2868 framebuffer. Compositing at the
// bezel's own size resamples the screen down by ~3x and throws the
// detail away before the picked size ever gets a look at it. Soft chrome
// around a sharp screen beats a sharp frame around a thumbnail.
const POINT_SCREEN = {
  viewport: { width: 474, height: 990 },
  rect: { x: 18, y: 18, width: 438, height: 954 },
  clipRadius: 62,
};

test('should grow the composite until the cutout is 1:1 with the frames', () => {
  const { CaptureComposer } = modules();
  const c = CaptureComposer.composite(
    { naturalWidth: 474 }, POINT_SCREEN, { width: 1320, height: 2868 }
  );
  assert.equal(c.scale, 1320 / 438);
  assert.deepEqual({ width: c.width, height: c.height }, { width: 1428, height: 2984 });
});

test('should leave a bezel-less composite at 1:1', () => {
  const { CaptureComposer } = modules();
  assert.deepEqual(
    CaptureComposer.composite(null, POINT_SCREEN, { width: 1320, height: 2868 }),
    { width: 1320, height: 2868, scale: 1 }
  );
});

test('should never shrink a bezel authored larger than the framebuffer', () => {
  const { CaptureComposer } = modules();
  const c = CaptureComposer.composite(
    { naturalWidth: 1400 }, SCREEN, { width: 640, height: 1388 }
  );
  assert.equal(c.scale, 1);
  assert.deepEqual({ width: c.width, height: c.height }, { width: 1400, height: 2900 });
});

// A canvas the browser refuses to allocate paints nothing at all, so the
// growth is bounded even if a source turns up absurdly larger than its
// cutout.
test('should cap the growth when the source is outsized', () => {
  const { CaptureComposer } = modules();
  assert.equal(
    CaptureComposer.composite(
      { naturalWidth: 200 },
      { viewport: { width: 200, height: 400 }, rect: { x: 0, y: 0, width: 100, height: 200 } },
      { width: 1000, height: 2000 }
    ).scale,
    4
  );
});

test('should report nothing to paint when there is neither a bezel nor a decoded frame', () => {
  const { CaptureComposer } = modules();
  assert.deepEqual(
    CaptureComposer.composite({ naturalWidth: 0 }, POINT_SCREEN, { width: 0, height: 0 }),
    { width: 0, height: 0, scale: 1 }
  );
});
