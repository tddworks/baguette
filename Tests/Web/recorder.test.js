'use strict';

// BrowserRecorder's behaviour, driven against a hand-rolled browser: a
// fake `document` handing out fake canvases, a queued
// `requestAnimationFrame` so the paint loop advances one frame per test
// step instead of spinning, and a `MediaRecorder` stand-in whose chunks
// are plain `{ size }` objects. No jsdom — the recorder only ever touches
// this narrow slice of the DOM, so the fake is enough to assert on the
// state that matters: the compose canvas the recording is captured from,
// where each frame lands inside it, and the artifact that comes back.

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { loadBrowserModules } = require('./helpers/load-browser-module.js');

const WEB = path.join(
  __dirname, '..', '..', 'Sources', 'Baguette', 'Resources', 'Web'
);
const FILES = [
  path.join(WEB, 'capture', 'capture-size.js'),
  path.join(WEB, 'capture', 'capture-settings.js'),
  path.join(WEB, 'capture', 'capture-composer.js'),
  path.join(WEB, 'capture', 'recorder.js'),
];

// ── the fake browser ─────────────────────────────────────────

// Tracks the current transform and records every paint in FINAL canvas
// pixels — same shape as capture-composer.test.js's, so an assertion
// reads as "this ended up here on the recording".
function fakeCtx() {
  const ops = [];
  let m = { x: 0, y: 0, sx: 1, sy: 1 };
  const stack = [];
  return {
    ops,
    fillStyle: '',
    strokeStyle: '',
    lineWidth: 0,
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
    arc(cx, cy, r) { ops.push(['arc', m.x + cx * m.sx, m.y + cy * m.sy, r * m.sx]); },
    fill() {}, stroke() {},
  };
}

function fakeCanvas(tag) {
  const ctx = fakeCtx();
  return {
    tag: tag || 'compose',
    width: 0,
    height: 0,
    getContext() { return ctx; },
    captureStream(fps) {
      this.capturedFps = fps;
      // captureStream binds to THIS canvas' backing surface — resizing it
      // afterwards is what the recorder is not allowed to do.
      this.capturedSize = { width: this.width, height: this.height };
      return { tag: 'stream' };
    },
    ctx,
  };
}

class FakeMediaRecorder {
  static isTypeSupported(mime) {
    return FakeMediaRecorder.supported.indexOf(mime) >= 0;
  }

  constructor(stream, opts) {
    this.stream = stream;
    this.opts = opts;
    this.state = 'inactive';
    FakeMediaRecorder.instances.push(this);
  }

  start(timeslice) { this.state = 'recording'; this.timeslice = timeslice; }

  requestData() {
    if (this.ondataavailable) this.ondataavailable({ data: { size: 4096 } });
  }

  stop() {
    this.state = 'inactive';
    if (this.onstop) this.onstop();
  }
}
FakeMediaRecorder.supported = ['video/mp4;codecs=avc1.42E01E'];
FakeMediaRecorder.instances = [];

class FakeBlob {
  constructor(parts, opts) {
    this.size = parts.reduce((sum, p) => sum + (p.size || 0), 0);
    this.type = (opts || {}).type || '';
  }
}

/** A throwaway `window` with just the APIs BrowserRecorder reaches for. */
function fakeWindow(overrides) {
  const created = [];
  const frames = [];
  const win = {
    document: {
      createElement() {
        const canvas = fakeCanvas();
        created.push(canvas);
        return canvas;
      },
    },
    requestAnimationFrame(cb) { frames.push(cb); return frames.length; },
    cancelAnimationFrame() { frames.length = 0; },
    MediaRecorder: FakeMediaRecorder,
    Blob: FakeBlob,
    URL: { createObjectURL() { return 'blob:fake-url'; } },
    _created: created,
    _frames: frames,
  };
  return Object.assign(win, overrides || {});
}

function load(overrides) {
  FakeMediaRecorder.instances = [];
  const win = fakeWindow(overrides);
  loadBrowserModules(FILES, win);
  return win;
}

/** Runs one queued rAF callback — the recorder re-queues the next itself. */
function flushFrame(win) {
  const cb = win._frames.shift();
  if (cb) cb();
}

// ── fixtures ─────────────────────────────────────────────────

// iPhone 16 Pro-ish: a 1206×2622 bezel viewport with the live screen
// inset 20px all round.
const BEZEL = { tag: 'bezel', naturalWidth: 1206, naturalHeight: 2622 };
const SCREEN = {
  viewport: { width: 1206, height: 2622 },
  rect: { x: 20, y: 20, width: 1166, height: 2582 },
  clipRadius: 60,
};

const sourceCanvas = (width, height) => ({ tag: 'live', width, height });

const drawOps = (ctx) => ctx.ops.filter((op) => op[0] === 'draw');

// ── availability ─────────────────────────────────────────────

test('recording is unavailable when the browser has no MediaRecorder', () => {
  const win = load({ MediaRecorder: undefined });
  assert.equal(win.BrowserRecorder.isAvailable(), false);
});

test('recording is available when MediaRecorder exists', () => {
  const win = load();
  assert.equal(win.BrowserRecorder.isAvailable(), true);
});

// ── idle costs nothing ───────────────────────────────────────

test('an idle recorder allocates no compose canvas and no paint loop', () => {
  const win = load();
  const rec = new win.BrowserRecorder({ canvas: sourceCanvas(1170, 2532) });
  assert.equal(win._created.length, 0);
  assert.equal(win._frames.length, 0);
  assert.equal(rec.compose, null);
  assert.equal(rec.recorder, null);
});

// ── output size ──────────────────────────────────────────────

test('the old call shape still records at the bezel composite size', () => {
  const win = load();
  const rec = new win.BrowserRecorder({
    canvas: sourceCanvas(1166, 2582),
    frameImg: BEZEL,
    screen: SCREEN,
    overlayHost: null,
    fps: 60,
  });
  rec.start();
  assert.equal(rec.compose.width, 1206);
  assert.equal(rec.compose.height, 2622);
});

test('an App Store 6.9 recording composes onto a 1290×2796 canvas', () => {
  const win = load();
  const settings = new win.Baguette._CaptureSettings({ size: 'appstore-6.9' });
  const rec = new win.BrowserRecorder({
    canvas: sourceCanvas(1166, 2582), frameImg: BEZEL, screen: SCREEN, settings,
  });
  rec.start();
  assert.equal(rec.compose.width, 1290);
  assert.equal(rec.compose.height, 2796);
});

test('a square recording grows the binding axis so the source stays 1:1', () => {
  const win = load();
  const rec = new win.BrowserRecorder({
    canvas: sourceCanvas(1166, 2582),
    frameImg: BEZEL,
    screen: SCREEN,
    captureSize: 'square',
  });
  rec.start();
  assert.equal(rec.compose.width, 2622);
  assert.equal(rec.compose.height, 2622);
});

test('a literal pixel spec sizes the recording exactly', () => {
  const win = load();
  const rec = new win.BrowserRecorder({
    canvas: sourceCanvas(1170, 2532), captureSize: '1920x1080',
  });
  rec.start();
  assert.equal(rec.compose.width, 1920);
  assert.equal(rec.compose.height, 1080);
});

// ── bezel-less (3D) mode ─────────────────────────────────────

test('a bezel-less recording sizes itself from the source canvas alone', () => {
  const win = load();
  const rec = new win.BrowserRecorder({
    canvas: sourceCanvas(800, 600), frameImg: BEZEL, screen: SCREEN, bezel: false,
  });
  rec.start();
  assert.equal(rec.compose.width, 800);
  assert.equal(rec.compose.height, 600);
});

test('a bezel-less frame paints only the source canvas, no device frame', () => {
  const win = load();
  const rec = new win.BrowserRecorder({
    canvas: sourceCanvas(800, 600), frameImg: BEZEL, screen: SCREEN, bezel: false,
  });
  rec.start();
  flushFrame(win);
  assert.deepEqual(drawOps(rec.composeCtx), [['draw', 'live', 0, 0, 800, 600]]);
});

test('a bezel-less 16:9 recording letterboxes the source into the target', () => {
  const win = load();
  const rec = new win.BrowserRecorder({
    canvas: sourceCanvas(800, 600), bezel: false, captureSize: '16:9',
    background: '#000000',
  });
  rec.start();
  flushFrame(win);
  assert.equal(rec.compose.width, 1067);
  assert.equal(rec.compose.height, 600);
  const [op] = drawOps(rec.composeCtx);
  assert.equal(op[1], 'live');
  assert.equal(op[2], 134);   // centred: (1067 - 800) / 2
  assert.equal(op[4], 800);
});

// DeviceKit authors its bezels in points — a 474 x 990 frame around a
// 438 x 954 cutout — while the live canvas carries the device's full
// 1320 x 2868 framebuffer. Recording at the bezel's own size resamples
// the screen down by ~3x before the picked size ever sees it.
const POINT_BEZEL = { tag: 'bezel', naturalWidth: 474, naturalHeight: 990 };
const POINT_SCREEN = {
  viewport: { width: 474, height: 990 },
  rect: { x: 18, y: 18, width: 438, height: 954 },
  clipRadius: 62,
};

test('a point-authored bezel records at the framebuffer resolution', () => {
  const win = load();
  const rec = new win.BrowserRecorder({
    canvas: sourceCanvas(1320, 2868), frameImg: POINT_BEZEL, screen: POINT_SCREEN,
  });
  rec.start();
  assert.equal(rec.compose.width, 1428);
  assert.equal(rec.compose.height, 2984);
});

test('the screen layer of a grown composite lands 1:1 with the frames', () => {
  const win = load();
  const rec = new win.BrowserRecorder({
    canvas: sourceCanvas(1320, 2868), frameImg: POINT_BEZEL, screen: POINT_SCREEN,
  });
  rec.start();
  flushFrame(win);
  const live = drawOps(rec.composeCtx).find((op) => op[1] === 'live');
  assert.equal(Math.round(live[4]), 1320);
  assert.equal(Math.round(live[5]), 2875);
});

// ── per-frame composition ────────────────────────────────────

test('a bezel frame paints the device frame under the clipped screen', () => {
  const win = load();
  const rec = new win.BrowserRecorder({
    canvas: sourceCanvas(1166, 2582), frameImg: BEZEL, screen: SCREEN,
  });
  rec.start();
  flushFrame(win);
  assert.deepEqual(drawOps(rec.composeCtx), [
    ['draw', 'bezel', 0, 0, 1206, 2622],
    ['draw', 'live', 20, 20, 1166, 2582],
  ]);
  assert.ok(rec.composeCtx.ops.some((op) => op[0] === 'clip'));
});

test('a resized target paints the background behind the letterboxed frame', () => {
  const win = load();
  const rec = new win.BrowserRecorder({
    canvas: sourceCanvas(1166, 2582), frameImg: BEZEL, screen: SCREEN,
    captureSize: 'square', background: '#ff0000',
  });
  rec.start();
  flushFrame(win);
  const fills = rec.composeCtx.ops.filter((op) => op[0] === 'fill');
  assert.deepEqual(fills[0], ['fill', '#ff0000', 0, 0, 2622, 2622]);
});

test('a native recording leaves no background mat under the frame', () => {
  const win = load();
  const rec = new win.BrowserRecorder({
    canvas: sourceCanvas(1166, 2582), frameImg: BEZEL, screen: SCREEN,
  });
  rec.start();
  flushFrame(win);
  assert.equal(rec.composeCtx.ops.filter((op) => op[0] === 'fill').length, 0);
});

// ── Record pressed before the first frame decodes ────────────

test('recording started before the first decoded frame still shows the device', () => {
  const win = load();
  const source = sourceCanvas(0, 0);
  const rec = new win.BrowserRecorder({
    canvas: source, frameImg: BEZEL, screen: SCREEN,
  });
  rec.start();
  assert.equal(rec.compose.width, 1206, 'sized from the bezel viewport, not 0');
  flushFrame(win);
  assert.deepEqual(drawOps(rec.composeCtx), [['draw', 'bezel', 0, 0, 1206, 2622]]);

  // …and the screen layer joins as soon as the stream negotiates.
  source.width = 1166;
  source.height = 2582;
  rec.composeCtx.ops.length = 0;
  flushFrame(win);
  assert.deepEqual(drawOps(rec.composeCtx), [
    ['draw', 'bezel', 0, 0, 1206, 2622],
    ['draw', 'live', 20, 20, 1166, 2582],
  ]);
});

// ── a source that reconfigures mid-recording ─────────────────

test('a source that resizes mid-recording is letterboxed into the locked size', () => {
  const win = load();
  const source = sourceCanvas(800, 600);
  const rec = new win.BrowserRecorder({ canvas: source, bezel: false });
  rec.start();
  flushFrame(win);

  // The stream reconfigured to a narrower scale — same recording.
  source.width = 400;
  source.height = 600;
  rec.composeCtx.ops.length = 0;
  flushFrame(win);

  assert.equal(rec.compose.width, 800, 'compose canvas must not be resized');
  assert.equal(rec.compose.height, 600);
  assert.deepEqual(drawOps(rec.composeCtx), [['draw', 'live', 200, 0, 400, 600]]);
});

test('captureStream is bound to the size the compose canvas keeps', () => {
  const win = load();
  const source = sourceCanvas(800, 600);
  const rec = new win.BrowserRecorder({ canvas: source, bezel: false });
  rec.start();
  source.width = 1600;
  source.height = 1200;
  flushFrame(win);
  assert.deepEqual(rec.compose.capturedSize, { width: 800, height: 600 });
  assert.equal(rec.compose.width, 800);
});

// ── the artifact ─────────────────────────────────────────────

test('the artifact filename carries the chosen size', async () => {
  const win = load();
  const rec = new win.BrowserRecorder({
    canvas: sourceCanvas(1166, 2582), frameImg: BEZEL, screen: SCREEN,
    captureSize: 'square',
  });
  rec.start();
  const artifact = await rec.stop();
  assert.match(artifact.filename, /^simulator-.*-square-2622x2622\.mp4$/);
});

test('a native artifact names the bare output dimensions', async () => {
  const win = load();
  const rec = new win.BrowserRecorder({
    canvas: sourceCanvas(1166, 2582), frameImg: BEZEL, screen: SCREEN,
  });
  rec.start();
  const artifact = await rec.stop();
  assert.match(artifact.filename, /^simulator-.*-1206x2622\.mp4$/);
});

test('stopping returns the blob, its size, and the negotiated mime type', async () => {
  const win = load();
  const rec = new win.BrowserRecorder({ canvas: sourceCanvas(800, 600), bezel: false });
  rec.start();
  const artifact = await rec.stop();
  assert.equal(artifact.mimeType, 'video/mp4;codecs=avc1.42E01E');
  assert.equal(artifact.bytes, 4096);
  assert.equal(artifact.blob.size, 4096);
  assert.equal(artifact.url, 'blob:fake-url');
  assert.ok(artifact.durationSeconds >= 0);
});

test('a WebM-only browser falls back to a .webm artifact', async () => {
  FakeMediaRecorder.supported = ['video/webm;codecs=vp9'];
  try {
    const win = load();
    const rec = new win.BrowserRecorder({ canvas: sourceCanvas(800, 600), bezel: false });
    rec.start();
    const artifact = await rec.stop();
    assert.equal(artifact.mimeType, 'video/webm;codecs=vp9');
    assert.match(artifact.filename, /\.webm$/);
  } finally {
    FakeMediaRecorder.supported = ['video/mp4;codecs=avc1.42E01E'];
  }
});

test('stopping tears the compose canvas and paint loop back down', async () => {
  const win = load();
  const rec = new win.BrowserRecorder({ canvas: sourceCanvas(800, 600), bezel: false });
  rec.start();
  await rec.stop();
  assert.equal(rec.compose, null);
  assert.equal(rec.composeCtx, null);
  assert.equal(rec.recorder, null);
  assert.equal(rec.rafId, null);
});

test('cancelling discards the chunks and the compose canvas', () => {
  const win = load();
  const rec = new win.BrowserRecorder({ canvas: sourceCanvas(800, 600), bezel: false });
  rec.start();
  rec.cancel();
  assert.equal(rec.compose, null);
  assert.equal(rec.recorder, null);
  assert.deepEqual(rec.chunks, []);
});

// ── recorder configuration ───────────────────────────────────

test('the default fps and bitrate survive the rewrite', () => {
  const win = load();
  const rec = new win.BrowserRecorder({ canvas: sourceCanvas(800, 600), bezel: false });
  rec.start();
  assert.equal(rec.compose.capturedFps, 60);
  assert.equal(FakeMediaRecorder.instances[0].opts.videoBitsPerSecond, 12_000_000);
});

test('settings drive the bezel unless the caller overrides it', () => {
  const win = load();
  const settings = new win.Baguette._CaptureSettings({ withFrame: false });
  const rec = new win.BrowserRecorder({
    canvas: sourceCanvas(800, 600), frameImg: BEZEL, screen: SCREEN, settings,
  });
  rec.start();
  assert.equal(rec.compose.width, 800);
  assert.equal(rec.compose.height, 600);
});

test('starting without a source canvas is refused', () => {
  const win = load();
  const rec = new win.BrowserRecorder({});
  assert.throws(() => rec.start(), /canvas is required/);
});

test('a MediaRecorder that refuses to start leaves no paint loop behind', () => {
  const win = load();
  win.MediaRecorder = class {
    static isTypeSupported() { return false; }
    constructor() { throw new Error('unsupported'); }
  };
  const rec = new win.BrowserRecorder({ canvas: sourceCanvas(800, 600), bezel: false });
  assert.throws(() => rec.start(), /unsupported/);
  assert.equal(rec.rafId, null);
  assert.equal(rec.compose, null);
  assert.equal(win._frames.length, 0);
});

// ── the pinch HUD ────────────────────────────────────────────

test('pinch dots are painted in the live screen’s coordinates', () => {
  const win = load();
  const overlayHost = {
    children: [{ style: { left: '50px', top: '100px' } }],
    getBoundingClientRect() { return { width: 583, height: 1291 }; },
  };
  const rec = new win.BrowserRecorder({
    canvas: sourceCanvas(1166, 2582), frameImg: BEZEL, screen: SCREEN, overlayHost,
  });
  rec.start();
  flushFrame(win);
  const arcs = rec.composeCtx.ops.filter((op) => op[0] === 'arc');
  // host is half the screen rect, so a dot at (50, 100) lands at
  // rect origin + double: (20 + 100, 20 + 200).
  assert.deepEqual(arcs, [['arc', 120, 220, 36]]);
});

test('a ratio size stays filesystem-safe in the filename (CaptureSettings.slug)', async () => {
  const win = load();
  const rec = new win.BrowserRecorder({
    canvas: sourceCanvas(1166, 2582), frameImg: BEZEL, screen: SCREEN,
    captureSize: '16:9',
  });
  rec.start();
  const artifact = await rec.stop();
  assert.equal(artifact.filename.includes(':'), false);
  assert.match(artifact.filename, /-16-9-4661x2622\.mp4$/);
});

// ── the capture vocabulary is an enhancement, not a dependency ──

/** Loads recorder.js ALONE — no capture/*.js on the page. */
function loadBare(overrides) {
  FakeMediaRecorder.instances = [];
  const win = fakeWindow(overrides);
  loadBrowserModules([path.join(WEB, 'capture', 'recorder.js')], win);
  return win;
}

test('without the capture modules a bezel recording still uses the viewport', () => {
  const win = loadBare();
  const rec = new win.BrowserRecorder({
    canvas: sourceCanvas(1166, 2582), frameImg: BEZEL, screen: SCREEN,
  });
  rec.start();
  assert.equal(rec.compose.width, 1206);
  assert.equal(rec.compose.height, 2622);
  flushFrame(win);
  assert.deepEqual(drawOps(rec.composeCtx), [
    ['draw', 'bezel', 0, 0, 1206, 2622],
    ['draw', 'live', 20, 20, 1166, 2582],
  ]);
});

test('without the capture modules a bezel-less recording uses the source size', () => {
  const win = loadBare();
  const rec = new win.BrowserRecorder({
    canvas: sourceCanvas(900, 1400), frameImg: BEZEL, screen: SCREEN, bezel: false,
  });
  rec.start();
  assert.equal(rec.compose.width, 900);
  assert.equal(rec.compose.height, 1400);
  flushFrame(win);
  assert.deepEqual(drawOps(rec.composeCtx), [['draw', 'live', 0, 0, 900, 1400]]);
});

test('without the capture modules an undecoded source still shows the device', () => {
  const win = loadBare();
  const rec = new win.BrowserRecorder({
    canvas: sourceCanvas(0, 0), frameImg: BEZEL, screen: SCREEN,
  });
  rec.start();
  assert.equal(rec.compose.width, 1206);
  flushFrame(win);
  assert.deepEqual(drawOps(rec.composeCtx), [['draw', 'bezel', 0, 0, 1206, 2622]]);
});

test('without the capture modules a requested size is ignored, not fatal', async () => {
  const win = loadBare();
  const warnings = [];
  win.console = { warn: (msg) => warnings.push(msg) };
  const rec = new win.BrowserRecorder({
    canvas: sourceCanvas(1166, 2582), frameImg: BEZEL, screen: SCREEN,
    captureSize: 'appstore-6.9',
  });
  rec.start();
  assert.equal(rec.compose.width, 1206, 'falls back to the natural composite');
  assert.equal(warnings.length, 1);
  assert.match(warnings[0], /capture/i);
  const artifact = await rec.stop();
  assert.match(artifact.filename, /^simulator-.*-1206x2622\.mp4$/);
});

test('the missing-vocabulary warning is logged once, not once per recorder', () => {
  const win = loadBare();
  const warnings = [];
  win.console = { warn: (msg) => warnings.push(msg) };
  for (let i = 0; i < 3; i += 1) {
    new win.BrowserRecorder({ canvas: sourceCanvas(800, 600), bezel: false }).start();
  }
  assert.equal(warnings.length, 1);
});

// ── a frame that lands after teardown ────────────────────────

test('a rAF tick that lands after teardown paints nothing', async () => {
  const win = load();
  const rec = new win.BrowserRecorder({ canvas: sourceCanvas(800, 600), bezel: false });
  rec.start();
  const queued = win._frames[0];
  await rec.stop();
  assert.doesNotThrow(() => queued());
});
