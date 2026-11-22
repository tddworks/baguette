import test from 'node:test';
import assert from 'node:assert/strict';
import { BrowserRecorder } from '../../../Sources/Baguette/Resources/Web/capture/recorder.js';
import { CaptureSettings } from '../../../Sources/Baguette/Resources/Web/capture/capture-settings.js';

// BrowserRecorder's behaviour, driven against a hand-rolled browser: a
// fake `document` handing out fake canvases, a queued
// `requestAnimationFrame` so the paint loop advances one frame per test
// step instead of spinning, and a `MediaRecorder` stand-in whose chunks
// are plain `{ size }` objects. No jsdom — the recorder only ever touches
// this narrow slice of the DOM, so the fake is enough to assert on the
// state that matters: the compose canvas the recording is captured from,
// where each frame lands inside it, and the artifact that comes back.


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

// The recorder reads the browser off the global `window` when it runs;
// each test installs its own and the original comes back after.
const realWindow = globalThis.window;
test.afterEach(() => { globalThis.window = realWindow; });

function load(overrides) {
  FakeMediaRecorder.instances = [];
  const win = fakeWindow(overrides);
  globalThis.window = win;
  win.BrowserRecorder = BrowserRecorder;
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

test('should be unavailable when the browser has no MediaRecorder', () => {
  const win = load({ MediaRecorder: undefined });
  assert.equal(win.BrowserRecorder.isAvailable(), false);
});

test('should be available when MediaRecorder exists', () => {
  const win = load();
  assert.equal(win.BrowserRecorder.isAvailable(), true);
});

// ── idle costs nothing ───────────────────────────────────────

test('should hold no compose canvas and no paint loop while idle', () => {
  const win = load();
  const rec = new win.BrowserRecorder({ canvas: sourceCanvas(1170, 2532) });
  assert.equal(win._created.length, 0);
  assert.equal(win._frames.length, 0);
  assert.equal(rec.compose, null);
  assert.equal(rec.recorder, null);
});

// ── output size ──────────────────────────────────────────────

test('should record at the bezel composite size through the old call shape', () => {
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

test('should compose an App Store 6.9 recording onto a 1290×2796 canvas', () => {
  const win = load();
  const settings = new CaptureSettings({ size: 'appstore-6.9' });
  const rec = new win.BrowserRecorder({
    canvas: sourceCanvas(1166, 2582), frameImg: BEZEL, screen: SCREEN, settings,
  });
  rec.start();
  assert.equal(rec.compose.width, 1290);
  assert.equal(rec.compose.height, 2796);
});

test('should grow the binding axis of a square recording so the source stays 1:1', () => {
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

test('should size the recording exactly to a literal pixel spec', () => {
  const win = load();
  const rec = new win.BrowserRecorder({
    canvas: sourceCanvas(1170, 2532), captureSize: '1920x1080',
  });
  rec.start();
  assert.equal(rec.compose.width, 1920);
  assert.equal(rec.compose.height, 1080);
});

// ── bezel-less (3D) mode ─────────────────────────────────────

test('should size a bezel-less recording from the source canvas alone', () => {
  const win = load();
  const rec = new win.BrowserRecorder({
    canvas: sourceCanvas(800, 600), frameImg: BEZEL, screen: SCREEN, bezel: false,
  });
  rec.start();
  assert.equal(rec.compose.width, 800);
  assert.equal(rec.compose.height, 600);
});

test('should paint only the source canvas when bezel-less', () => {
  const win = load();
  const rec = new win.BrowserRecorder({
    canvas: sourceCanvas(800, 600), frameImg: BEZEL, screen: SCREEN, bezel: false,
  });
  rec.start();
  flushFrame(win);
  assert.deepEqual(drawOps(rec.composeCtx), [['draw', 'live', 0, 0, 800, 600]]);
});

test('should letterbox a bezel-less 16:9 recording into the target', () => {
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

test('should record a point-authored bezel at the framebuffer resolution', () => {
  const win = load();
  const rec = new win.BrowserRecorder({
    canvas: sourceCanvas(1320, 2868), frameImg: POINT_BEZEL, screen: POINT_SCREEN,
  });
  rec.start();
  assert.equal(rec.compose.width, 1428);
  assert.equal(rec.compose.height, 2984);
});

test('should land the screen layer of a grown composite 1:1 with the frames', () => {
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

test('should paint the device frame under the clipped screen', () => {
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

test('should paint the background behind a letterboxed frame', () => {
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

test('should leave no background mat under a native recording', () => {
  const win = load();
  const rec = new win.BrowserRecorder({
    canvas: sourceCanvas(1166, 2582), frameImg: BEZEL, screen: SCREEN,
  });
  rec.start();
  flushFrame(win);
  assert.equal(rec.composeCtx.ops.filter((op) => op[0] === 'fill').length, 0);
});

// ── Record pressed before the first frame decodes ────────────

test('should still show the device when recording starts before the first frame', () => {
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

test('should letterbox a source that resizes mid-recording into the locked size', () => {
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

test('should capture the stream at the size the compose canvas keeps', () => {
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

test('should name the artifact after the chosen size', async () => {
  const win = load();
  const rec = new win.BrowserRecorder({
    canvas: sourceCanvas(1166, 2582), frameImg: BEZEL, screen: SCREEN,
    captureSize: 'square',
  });
  rec.start();
  const artifact = await rec.stop();
  assert.match(artifact.filename, /^simulator-.*-square-2622x2622\.mp4$/);
});

test('should name a native artifact by its output dimensions', async () => {
  const win = load();
  const rec = new win.BrowserRecorder({
    canvas: sourceCanvas(1166, 2582), frameImg: BEZEL, screen: SCREEN,
  });
  rec.start();
  const artifact = await rec.stop();
  assert.match(artifact.filename, /^simulator-.*-1206x2622\.mp4$/);
});

test('should hand back the blob, its size and the mime type when stopped', async () => {
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

test('should fall back to a .webm artifact in a WebM-only browser', async () => {
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

test('should tear down the compose canvas and paint loop when stopped', async () => {
  const win = load();
  const rec = new win.BrowserRecorder({ canvas: sourceCanvas(800, 600), bezel: false });
  rec.start();
  await rec.stop();
  assert.equal(rec.compose, null);
  assert.equal(rec.composeCtx, null);
  assert.equal(rec.recorder, null);
  assert.equal(rec.rafId, null);
});

test('should discard the chunks and the compose canvas when cancelled', () => {
  const win = load();
  const rec = new win.BrowserRecorder({ canvas: sourceCanvas(800, 600), bezel: false });
  rec.start();
  rec.cancel();
  assert.equal(rec.compose, null);
  assert.equal(rec.recorder, null);
  assert.deepEqual(rec.chunks, []);
});

// ── recorder configuration ───────────────────────────────────

test('should keep the default fps and bitrate', () => {
  const win = load();
  const rec = new win.BrowserRecorder({ canvas: sourceCanvas(800, 600), bezel: false });
  rec.start();
  assert.equal(rec.compose.capturedFps, 60);
  assert.equal(FakeMediaRecorder.instances[0].opts.videoBitsPerSecond, 12_000_000);
});

test('should take the bezel from the settings unless the caller overrides it', () => {
  const win = load();
  const settings = new CaptureSettings({ withFrame: false });
  const rec = new win.BrowserRecorder({
    canvas: sourceCanvas(800, 600), frameImg: BEZEL, screen: SCREEN, settings,
  });
  rec.start();
  assert.equal(rec.compose.width, 800);
  assert.equal(rec.compose.height, 600);
});

test('should refuse to start without a source canvas', () => {
  const win = load();
  const rec = new win.BrowserRecorder({});
  assert.throws(() => rec.start(), /canvas is required/);
});

test('should leave no paint loop behind when MediaRecorder refuses to start', () => {
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

test('should paint pinch dots in the live screen’s coordinates', () => {
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

test('should keep a ratio size filesystem-safe in the filename', async () => {
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

// ── a frame that lands after teardown ────────────────────────

test('should paint nothing when a frame lands after teardown', async () => {
  const win = load();
  const rec = new win.BrowserRecorder({ canvas: sourceCanvas(800, 600), bezel: false });
  rec.start();
  const queued = win._frames[0];
  await rec.stop();
  assert.doesNotThrow(() => queued());
});
