// CaptureSize — the output size a screenshot or a recording should come
// out at, as one value. The whole app speaks this vocabulary: the toolbar
// picker, CaptureGallery, BrowserRecorder, Sim3DPanel, and the Swift
// `CaptureSize` behind `baguette screenshot --size` / `?size=` all use the
// same preset ids and the same placement maths, so "App Store 6.9" means
// exactly one thing everywhere.
//
//   const size = CaptureSize.parse('appstore-6.9');   // or 'square', '1920x1080'
//   size.resolve(1290, 2796);          // → { width: 1290, height: 2796 }
//   size.plan(1290, 2796, 'contain');  // → { width, height, drawX, drawY, drawW, drawH }
//
// Three flavours of size, all behind the same interface:
//   • native  — whatever the source already is; every plan is a no-op.
//   • fixed   — an exact pixel size (the App Store submission sizes).
//   • ratio   — an aspect ratio resolved against the source. A ratio NEVER
//               downscales: it grows the binding axis so the source still
//               fits at 1:1. A 1290×2796 phone asked for `square` gets a
//               2796×2796 canvas, not a 1290×1290 crop.
//
// `plan(sourceW, sourceH, fit)` is the only geometry anyone needs — it
// returns both the canvas size and where to draw the source inside it, so
// callers just allocate and `drawImage`. See capture-composer.js.
const FITS = ['contain', 'cover', 'stretch'];

class CaptureSize {
  /**
   * @param {object} spec
   * @param {string} spec.id      preset id, `custom`, or `ratio`
   * @param {string} spec.label   human label for the picker
   * @param {string} spec.spec    round-trippable through `parse`
   * @param {'native'|'fixed'|'ratio'} spec.kind
   * @param {number} [spec.width]   fixed kind: exact pixels
   * @param {number} [spec.height]  fixed kind: exact pixels
   * @param {number} [spec.ratio]   ratio kind: width / height
   * @param {string} [spec.code]    the chip's spelling — at most four
   *        tabular characters, so the toolbar can hold one width
   */
  constructor({ id, label, code, spec, kind, width, height, ratio }) {
    this.id = id;
    this.label = label;
    // The toolbar chip used to render `label`, so it was "Native"
    // (54px) one moment and "App Store iPad 13″" (132px) the next —
    // the one control whose width the user changes by using it, in a
    // bar that is a single row of fixed-size controls.
    this.code = code || spec;
    this.spec = spec;
    this.kind = kind;
    this.width = width || 0;
    this.height = height || 0;
    this.ratio = ratio || 0;
  }

  /** The ordered catalogue the picker renders. */
  static presets() {
    return PRESETS.map((p) => new CaptureSize(p));
  }

  /** Look one preset up by id. `null` when it isn't one. */
  static named(id) {
    const found = PRESETS.find((p) => p.id === id);
    return found ? new CaptureSize(found) : null;
  }

  static get fits() {
    return FITS.slice();
  }

  /** The default every surface starts on. */
  static native() {
    return CaptureSize.named('native');
  }

  /**
   * Preset id (`square`), literal pixels (`1920x1080`), or a bare ratio
   * (`3:2`). Returns `null` for anything else — callers fall back to
   * native rather than guessing at a user's typo.
   */
  static parse(spec) {
    if (typeof spec !== 'string') return null;
    const text = spec.trim().toLowerCase();
    if (!text) return null;

    const preset = CaptureSize.named(text);
    if (preset) return preset;

    const pixels = /^(\d+)\s*x\s*(\d+)$/.exec(text);
    if (pixels) {
      const width = Number(pixels[1]);
      const height = Number(pixels[2]);
      if (width <= 0 || height <= 0) return null;
      return new CaptureSize({
        id: 'custom',
        label: `${width} × ${height}`,
        // "1920x1080" is wider than the label it would replace, so
        // the chip says Custom and the popover's resolved dimensions
        // say which.
        code: 'Custom',
        spec: `${width}x${height}`,
        kind: 'fixed',
        width,
        height,
      });
    }

    const ratio = /^(\d+)\s*:\s*(\d+)$/.exec(text);
    if (ratio) {
      const w = Number(ratio[1]);
      const h = Number(ratio[2]);
      if (w <= 0 || h <= 0) return null;
      return new CaptureSize({
        id: 'ratio',
        label: `${w}:${h}`,
        spec: `${w}:${h}`,
        kind: 'ratio',
        ratio: w / h,
      });
    }
    return null;
  }

  get isNative() {
    return this.kind === 'native';
  }

  /**
   * The shape this size wants, as width / height — or `null` for
   * `native`, which has no shape of its own and takes the source's.
   *
   * Read straight off the value rather than recovered from a
   * `resolve()` call: resolve rounds to whole pixels, and 1778/1000
   * is not 16/9. Callers draw it (the chip's glyph) or stream at it,
   * and both want the ratio the user asked for.
   */
  aspect() {
    if (this.isNative) return null;
    if (this.kind === 'ratio') return this.ratio > 0 ? this.ratio : null;
    return this.width > 0 && this.height > 0 ? this.width / this.height : null;
  }

  /** The canvas dimensions this size wants for a given source. */
  resolve(sourceWidth, sourceHeight) {
    const sw = Math.max(0, Math.round(sourceWidth || 0));
    const sh = Math.max(0, Math.round(sourceHeight || 0));
    if (this.kind === 'fixed') return { width: this.width, height: this.height };
    if (this.kind === 'native' || sw === 0 || sh === 0) {
      return { width: sw, height: sh };
    }
    // Grow the binding axis so the source always fits at 1:1.
    return sw / sh > this.ratio
      ? { width: sw, height: Math.round(sw / this.ratio) }
      : { width: Math.round(sh * this.ratio), height: sh };
  }

  /**
   * Canvas size + where the source lands inside it. The plan also
   * carries the source dimensions it was computed from, so a painter
   * (see capture-composer.js) can recover the scale without being told
   * the source size a second time.
   *
   * `contain` letterboxes and centres, `cover` fills and lets the
   * overflow crop, `stretch` distorts to fill exactly.
   */
  plan(sourceWidth, sourceHeight, fit) {
    const sw = Math.max(0, Math.round(sourceWidth || 0));
    const sh = Math.max(0, Math.round(sourceHeight || 0));
    const { width, height } = this.resolve(sw, sh);

    const box = { sourceWidth: sw, sourceHeight: sh };
    if (width === 0 || height === 0 || sw === 0 || sh === 0) {
      return { width, height, drawX: 0, drawY: 0, drawW: 0, drawH: 0, ...box };
    }
    if (this.kind === 'native' || (FITS.indexOf(fit) >= 0 ? fit : 'contain') === 'stretch') {
      return {
        width, height, drawX: 0, drawY: 0, drawW: width, drawH: height, ...box,
      };
    }
    const mode = FITS.indexOf(fit) >= 0 ? fit : 'contain';
    const sx = width / sw;
    const sy = height / sh;
    const scale = mode === 'cover' ? Math.max(sx, sy) : Math.min(sx, sy);
    const drawW = Math.round(sw * scale);
    const drawH = Math.round(sh * scale);
    return {
      width,
      height,
      drawX: Math.round((width - drawW) / 2),
      drawY: Math.round((height - drawH) / 2),
      drawW,
      drawH,
      ...box,
    };
  }
}

// Plain data so `presets()` can hand out fresh instances each call and
// nothing shares mutable state. `spec` is what goes on the wire and into
// localStorage; for presets it is just the id.
const PRESETS = [
  { id: 'native', label: 'Native', code: 'Auto', spec: 'native', kind: 'native' },
  {
    id: 'appstore-6.9', label: 'App Store 6.9″', code: '6.9″', spec: 'appstore-6.9',
    kind: 'fixed', width: 1290, height: 2796,
  },
  {
    id: 'appstore-6.5', label: 'App Store 6.5″', code: '6.5″', spec: 'appstore-6.5',
    kind: 'fixed', width: 1242, height: 2688,
  },
  {
    id: 'appstore-ipad-13', label: 'App Store iPad 13″', code: '13″', spec: 'appstore-ipad-13',
    kind: 'fixed', width: 2064, height: 2752,
  },
  { id: 'square', label: 'Square', code: '1:1', spec: 'square', kind: 'ratio', ratio: 1 },
  { id: '16:9', label: 'Landscape 16:9', spec: '16:9', kind: 'ratio', ratio: 16 / 9 },
  { id: '9:16', label: 'Portrait 9:16', spec: '9:16', kind: 'ratio', ratio: 9 / 16 },
  { id: '4:3', label: 'Classic 4:3', spec: '4:3', kind: 'ratio', ratio: 4 / 3 },
  { id: '4:5', label: 'Social 4:5', spec: '4:5', kind: 'ratio', ratio: 4 / 5 },
];

export { CaptureSize };
