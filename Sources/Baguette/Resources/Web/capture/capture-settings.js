// CaptureSettings — everything the user picked about how a capture should
// come out, as one immutable value: the target CaptureSize, the fit, the
// letterbox background, and whether the device bezel is composited in.
//
// Every capture surface holds one of these and hands it around instead of
// four loose arguments: the toolbar picker edits it, CaptureGallery and
// BrowserRecorder read `plan()` / `effectiveBackground` off it, and the
// HTTP routes take `toQuery()` verbatim (`?size=&fit=&background=`, the
// same names `baguette screenshot` uses for its flags).
//
//   let settings = CaptureSettings.restore(localStorage, 'asc.capture');
//   settings = settings.with({ size: 'appstore-6.9' });
//   settings.persist(localStorage, 'asc.capture');
//   const plan = settings.plan(canvas.width, canvas.height);
//
// Nothing here touches the DOM — see capture-size-menu.js for the picker.

import { CaptureSize } from './capture-size.js';

const FITS = ['contain', 'cover', 'stretch'];
const DEFAULT_BACKGROUND = '#ffffff';

class CaptureSettings {
  /**
   * @param {object} [opts]
   * @param {string} [opts.size]        CaptureSize spec; bad input → native
   * @param {string} [opts.fit]         contain | cover | stretch
   * @param {string} [opts.background]  'transparent' or a #RRGGBB colour
   * @param {boolean} [opts.withFrame]  composite the device bezel
   */
  constructor(opts) {
    const o = opts || {};
    this.size = CaptureSize.parse(o.size || 'native') || CaptureSize.native();
    this.fit = FITS.indexOf(o.fit) >= 0 ? o.fit : 'contain';
    this.background = o.background || DEFAULT_BACKGROUND;
    this.withFrame = o.withFrame === undefined ? true : !!o.withFrame;
  }

  /** A copy with some fields replaced. */
  with(changes) {
    return new CaptureSettings({
      size: this.size.spec,
      fit: this.fit,
      background: this.background,
      withFrame: this.withFrame,
      ...(changes || {}),
    });
  }

  /** Canvas size + source placement for a given source. */
  plan(sourceWidth, sourceHeight) {
    return this.size.plan(sourceWidth, sourceHeight, this.fit);
  }

  /**
   * The background that will actually be visible. At native size the
   * source covers the canvas edge to edge, so a colour would only ever
   * paint underneath an opaque image — reporting `transparent` keeps a
   * PNG of a transparent 3D render from gaining an unwanted white mat.
   */
  get effectiveBackground() {
    return this.size.isNative ? 'transparent' : this.background;
  }

  /** `?size=&fit=&background=` — empty when nothing is being resized. */
  toQuery() {
    if (this.size.isNative) return {};
    return {
      size: this.size.spec,
      fit: this.fit,
      background: this.background,
    };
  }

  /**
   * Filename fragment: `appstore-6.9-1290x2796`, or bare dimensions at
   * native size. Ratio specs carry a colon, which is legal in an HFS+
   * filename but which the Finder renders as a slash — `16:9-…` shows
   * up in Downloads as `16/9-…`. Sanitising here, once, is what keeps
   * screenshots and recordings naming their files identically.
   */
  slug(width, height) {
    const dims = `${Math.round(width)}x${Math.round(height)}`;
    if (this.size.isNative) return dims;
    const spec = this.size.spec.replace(/[^A-Za-z0-9._-]+/g, '-');
    return `${spec}-${dims}`;
  }

  /**
   * Read a persisted selection back. Any failure — nothing stored, a
   * corrupt blob, a storage that throws (Safari private browsing) —
   * lands on the defaults rather than propagating.
   */
  static restore(storage, key) {
    try {
      const raw = storage.getItem(key);
      return new CaptureSettings(raw ? JSON.parse(raw) : undefined);
    } catch (_) {
      return new CaptureSettings();
    }
  }

  persist(storage, key) {
    try {
      storage.setItem(key, JSON.stringify({
        size: this.size.spec,
        fit: this.fit,
        background: this.background,
        withFrame: this.withFrame,
      }));
    } catch (_) { /* storage denied — the selection just won't survive a reload */ }
  }
}

export { CaptureSettings };
