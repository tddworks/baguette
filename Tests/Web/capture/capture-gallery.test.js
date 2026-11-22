import test from 'node:test';
import assert from 'node:assert/strict';
import { CaptureGallery } from '../../../Sources/Baguette/Resources/Web/capture/capture-gallery.js';
import { CaptureSettings } from '../../../Sources/Baguette/Resources/Web/capture/capture-settings.js';

// ── fake browser ─────────────────────────────────────────────
// CaptureGallery is the one capture surface that talks to the network
// AND the DOM, so the fake has to cover both: `fetch` + `FileReader` +
// `Image` for the screenshot round-trip, `document.createElement` for
// the canvas it composites on and the thumbnail strip it renders.
// Everything records state (URLs asked for, canvas dimensions, anchors
// clicked) so the tests assert on values rather than on call order.

class FakeNode {
  constructor(tag) {
    this.tagName = tag;
    this.style = {};
    this.children = [];
    this.textContent = '';
    this.title = '';
    this._listeners = new Map();
  }

  appendChild(child) { this.children.push(child); return child; }

  set innerHTML(_) { this.children = []; }

  get innerHTML() { return ''; }

  addEventListener(type, fn) {
    if (!this._listeners.has(type)) this._listeners.set(type, new Set());
    this._listeners.get(type).add(fn);
  }

  fire(type, event = {}) {
    for (const fn of this._listeners.get(type) || []) fn(event);
  }
}

function fakeWindow({ shot = { width: 1290, height: 2796 }, response } = {}) {
  const state = { urls: [], canvases: [], anchors: [], shot };

  const document = {
    createElement(tag) {
      if (tag === 'canvas') {
        const canvas = {
          width: 0,
          height: 0,
          getContext: () => ({
            fillStyle: '',
            save() {}, restore() {},
            translate() {}, scale() {},
            clearRect() {}, fillRect() {},
            drawImage() {},
            beginPath() {}, moveTo() {}, lineTo() {},
            quadraticCurveTo() {}, closePath() {}, clip() {},
          }),
          toDataURL: (type) => `data:${type};base64,W${canvas.width}H${canvas.height}`,
        };
        state.canvases.push(canvas);
        return canvas;
      }
      if (tag === 'a') {
        const a = { href: '', download: '', clicked: 0, click() { this.clicked += 1; } };
        state.anchors.push(a);
        return a;
      }
      return new FakeNode(tag);
    },
  };

  const window = {
    document,
    state,
    fetch(url) {
      state.urls.push(url);
      return Promise.resolve(response || {
        ok: true,
        status: 200,
        blob: () => Promise.resolve({ tag: 'blob' }),
      });
    },
    FileReader: class {
      readAsDataURL() {
        this.result = 'data:image/jpeg;base64,SHOT';
        queueMicrotask(() => this.onloadend && this.onloadend());
      }
    },
    Image: class {
      set src(value) {
        this._src = value;
        this.width = state.shot.width;
        this.height = state.shot.height;
        this.naturalWidth = state.shot.width;
        this.naturalHeight = state.shot.height;
        queueMicrotask(() => this.onload && this.onload());
      }

      get src() { return this._src; }
    },
  };
  return window;
}

const SCREEN = {
  viewport: { width: 1400, height: 2900 },
  rect: { x: 55, y: 52, width: 1290, height: 2796 },
  clipRadius: 130,
};

const BEZEL = { naturalWidth: 1400, naturalHeight: 2900, tag: 'bezel' };

// The gallery reads the browser off the global `window` when it runs;
// each test installs its own and the original comes back after.
const realWindow = globalThis.window;
test.afterEach(() => { globalThis.window = realWindow; });

function galleryFor({
  screen = SCREEN, frameImg = BEZEL, shot, response,
} = {}) {
  const window = fakeWindow({ shot, response });
  globalThis.window = window;
  const gallery = new CaptureGallery({ udid: 'UD-1', screen, frameImg });
  return { window, gallery, CaptureSettings, state: window.state };
}

const paramsOf = (url) => Object.fromEntries(new URL(url, 'http://x').searchParams);

// ── request ──────────────────────────────────────────────────

test('should ask the screenshot route for the picked size, fit and background', async () => {
  const { gallery, CaptureSettings, state } = galleryFor({ frameImg: null });
  await gallery.capture({
    settings: new CaptureSettings({
      size: 'appstore-6.9', fit: 'cover', background: '#101010', withFrame: false,
    }),
  });

  const q = paramsOf(state.urls[0]);
  assert.equal(q.size, 'appstore-6.9');
  assert.equal(q.fit, 'cover');
  assert.equal(q.background, '#101010');
});

test("should ask the device's own screenshot route", async () => {
  const { gallery, CaptureSettings, state } = galleryFor({ frameImg: null });
  await gallery.capture({ settings: new CaptureSettings({ withFrame: false }) });

  assert.match(state.urls[0], /^\/devices\/UD-1\/screenshot\.jpg\?/);
});

test('should ask for a plain screenshot at native size', async () => {
  const { gallery, CaptureSettings, state } = galleryFor({ frameImg: null });
  await gallery.capture({ settings: new CaptureSettings({ withFrame: false }) });

  const q = paramsOf(state.urls[0]);
  assert.equal(q.size, undefined);
  assert.equal(q.fit, undefined);
});

test('should ask for the raw screen when the bezel is composited in', async () => {
  const { gallery, CaptureSettings, state } = galleryFor();
  await gallery.capture({
    settings: new CaptureSettings({ size: 'square', withFrame: true }),
  });

  // The bezel composite needs an unpadded screen to paste into the
  // cutout — the resize happens after, around the whole composite.
  const q = paramsOf(state.urls[0]);
  assert.equal(q.size, undefined);
});

// ── canvas geometry ──────────────────────────────────────────

test('should size a framed capture to the preset, not the bezel', async () => {
  const { gallery, CaptureSettings, state } = galleryFor();
  const entry = await gallery.capture({
    settings: new CaptureSettings({ size: 'appstore-6.9', withFrame: true }),
  });

  assert.deepEqual(
    { w: state.canvases[0].width, h: state.canvases[0].height },
    { w: 1290, h: 2796 }
  );
  assert.deepEqual({ w: entry.w, h: entry.h }, { w: 1290, h: 2796 });
});

test('should grow a ratio size around the bezel viewport', async () => {
  const { gallery, CaptureSettings } = galleryFor();
  const entry = await gallery.capture({
    settings: new CaptureSettings({ size: 'square', withFrame: true }),
  });

  assert.deepEqual({ w: entry.w, h: entry.h }, { w: 2900, h: 2900 });
});

// DeviceKit authors its bezels in points — a 474 x 990 frame around a
// 438 x 954 cutout — while the screenshot route hands back the device's
// full 1320 x 2868 framebuffer. Compositing at the bezel's own size
// throws ~3x of the detail away before the picked size ever sees it.
const POINT_SCREEN = {
  viewport: { width: 474, height: 990 },
  rect: { x: 18, y: 18, width: 438, height: 954 },
  clipRadius: 62,
};
const POINT_BEZEL = { naturalWidth: 474, naturalHeight: 990, tag: 'bezel' };

test('should composite a point-authored bezel at the screenshot resolution', async () => {
  const { gallery, CaptureSettings } = galleryFor({
    screen: POINT_SCREEN,
    frameImg: POINT_BEZEL,
    shot: { width: 1320, height: 2868 },
  });
  const entry = await gallery.capture({
    settings: new CaptureSettings({ size: 'native', withFrame: true }),
  });

  assert.deepEqual({ w: entry.w, h: entry.h }, { w: 1428, h: 2984 });
});

test('should grow a ratio size around the raw screenshot when unframed', async () => {
  const { gallery, CaptureSettings } = galleryFor({ frameImg: null });
  const entry = await gallery.capture({
    settings: new CaptureSettings({ size: 'square', withFrame: false }),
  });

  assert.deepEqual({ w: entry.w, h: entry.h }, { w: 2796, h: 2796 });
});

test('should capture the bare bezel when the screenshot decodes to nothing', async () => {
  const { gallery, CaptureSettings } = galleryFor({ shot: { width: 0, height: 0 } });
  const entry = await gallery.capture({
    settings: new CaptureSettings({ withFrame: true }),
  });

  // Nothing to paste into the cutout, but the device frame is loaded and
  // worth having — an empty PNG would be the worse answer.
  assert.deepEqual({ w: entry.w, h: entry.h }, { w: 1400, h: 2900 });
  assert.equal(entry.dataUrl, 'data:image/png;base64,W1400H2900');
});

test('should size to the screenshot when there is no bezel image', async () => {
  const { gallery, CaptureSettings } = galleryFor({ frameImg: null });
  const entry = await gallery.capture({
    settings: new CaptureSettings({ withFrame: true }),
  });

  assert.equal(entry.withFrame, false);
  assert.deepEqual({ w: entry.w, h: entry.h }, { w: 1290, h: 2796 });
});

// ── entry metadata ───────────────────────────────────────────

test('should record the resolved pixels and the preset label', async () => {
  const { window, gallery, CaptureSettings } = galleryFor();
  await gallery.capture({
    settings: new CaptureSettings({ size: 'appstore-6.9', withFrame: true }),
  });

  const entry = window.simCaptures[0];
  assert.equal(entry.name, 'Screen 1');
  assert.equal(entry.sizeId, 'appstore-6.9');
  assert.equal(entry.sizeLabel, 'App Store 6.9″');
  assert.equal(entry.w, 1290);
  assert.equal(entry.h, 2796);
  assert.equal(entry.withFrame, true);
  assert.equal(entry.dataUrl, 'data:image/png;base64,W1290H2796');
});

test('should keep the server image when nothing needs redrawing', async () => {
  const { gallery, CaptureSettings, state } = galleryFor({ frameImg: null });
  const entry = await gallery.capture({
    settings: new CaptureSettings({ withFrame: false }),
  });

  // A native, unframed capture is exactly what the route already sent —
  // re-encoding it as PNG would multiply the retained bytes for nothing.
  assert.equal(entry.dataUrl, 'data:image/jpeg;base64,SHOT');
  assert.equal(state.canvases.length, 0);
});

test('should report the route error instead of a decode failure', async () => {
  const { gallery, CaptureSettings } = galleryFor({
    frameImg: null,
    response: {
      ok: false,
      status: 404,
      text: () => Promise.resolve('{"error":"unknown udid"}'),
    },
  });

  await assert.rejects(
    gallery.capture({ settings: new CaptureSettings({ withFrame: false }) }),
    /404.*unknown udid/s
  );
});

test('should composite no bezel for the legacy call shape unless it asks', async () => {
  const { gallery } = galleryFor();
  const entry = await gallery.capture({ naturalSize: { w: 1290, h: 2796 } });

  assert.equal(entry.withFrame, false);
});

test('should still capture through the legacy withFrame / naturalSize shape', async () => {
  const { window, gallery } = galleryFor({ frameImg: null });
  const entry = await gallery.capture({
    withFrame: false, naturalSize: { w: 1290, h: 2796 },
  });

  assert.deepEqual({ w: entry.w, h: entry.h }, { w: 1290, h: 2796 });
  assert.equal(window.simCaptures.length, 1);
});

// ── strip ────────────────────────────────────────────────────

test('should show the dimensions and the frame badge on the thumbnail', async () => {
  const { window, gallery, CaptureSettings } = galleryFor();
  await gallery.capture({
    settings: new CaptureSettings({ size: 'appstore-6.9', withFrame: true }),
  });

  const strip = window.document.createElement('div');
  const count = window.document.createElement('span');
  gallery.renderInto(strip, count);

  assert.equal(count.textContent, '(1)');
  assert.equal(strip.children.length, 1);
  const thumb = strip.children[0];
  assert.match(thumb.title, /1290 × 2796/);
  assert.match(thumb.title, /App Store 6.9/);
  assert.equal(thumb.children.some((c) => c.textContent === 'F'), true);
  assert.equal(thumb.children.some((c) => c.textContent === '1290×2796'), true);
});

test('should name the download after the capture number, preset and pixels', async () => {
  const { window, gallery, CaptureSettings, state } = galleryFor();
  const settings = new CaptureSettings({ size: 'appstore-6.9', withFrame: true });
  await gallery.capture({ settings });
  await gallery.capture({ settings });
  await gallery.capture({ settings });

  const strip = window.document.createElement('div');
  gallery.renderInto(strip, null);
  strip.children[2].children[0].fire('click');

  const a = state.anchors[state.anchors.length - 1];
  assert.equal(a.download, 'capture-3-appstore-6.9-1290x2796.png');
  assert.equal(a.href, 'data:image/png;base64,W1290H2796');
  assert.equal(a.clicked, 1);
});

test('should keep a ratio preset filename-safe', async () => {
  const { window, gallery, CaptureSettings, state } = galleryFor({ frameImg: null });
  await gallery.capture({
    settings: new CaptureSettings({ size: '16:9', withFrame: false }),
  });

  const strip = window.document.createElement('div');
  gallery.renderInto(strip, null);
  strip.children[0].children[0].fire('click');

  // CaptureSettings.slug() sanitises the `:` out of a ratio spec; this
  // guards that the strip's download name inherits that, rather than
  // the gallery re-deriving a name of its own.
  const a = state.anchors[state.anchors.length - 1];
  assert.equal(a.download, 'capture-1-16-9-4971x2796.png');
});

test('should empty the strip and the window.simCaptures mirror when cleared', async () => {
  const { window, gallery, CaptureSettings } = galleryFor();
  await gallery.capture({ settings: new CaptureSettings({ withFrame: true }) });
  gallery.clear();

  assert.deepEqual(window.simCaptures, []);

  const strip = window.document.createElement('div');
  const count = window.document.createElement('span');
  gallery.renderInto(strip, count);
  assert.equal(count.textContent, '');
  assert.equal(strip.children.length, 1);
  assert.match(strip.children[0].textContent, /No captures yet/);
});
