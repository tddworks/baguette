// BrowserRecorder — record the live view to a WebM/MP4 file at whatever
// output size the user picked. Spins up a compose canvas only while
// recording; idling costs zero. Reuses what's already in the page:
//
//   • canvas       — the live decoded canvas StreamSession is painting
//                    (the 3D view hands its own canvas here instead)
//   • frameImg     — the bezel <img> the Baguette SDK loaded
//   • screen       — the SDK `SimulatorDefinition.screen` block
//                    (`viewport`, `rect`, `clipRadius`). Used for the
//                    bezel cutout coords + corner radius.
//   • overlayHost  — PinchOverlay's DOM container (we read positions
//                    out of it each frame, no caching)
//
// Sizing, fit, background and bezel-compositing come from the shared
// capture vocabulary (capture/capture-size.js, capture-settings.js,
// capture-composer.js) — the same value a screenshot is taken through, so
// "App Store 6.9″" means one thing across the whole app.
//
// Options — ONE preferred shape, `settings`, with loose fallbacks so the
// original call sites keep working untouched:
//
//   new BrowserRecorder({
//     canvas, frameImg, screen, overlayHost,   // what to paint
//     settings,        // a CaptureSettings — the preferred way to size
//     captureSize,     // fallback: a CaptureSize or a spec ('square')
//     fit, background, // fallback: only read when `settings` is absent
//     bezel,           // false → the source already IS the device (3D)
//     fps, bitrate,
//   });
//   rec.start();
//   const artifact = await rec.stop();
//   //   { url, blob, filename, mimeType, durationSeconds, bytes }
//   rec.cancel();
//
// Omit everything but `canvas` and you get the historical behaviour:
// native size, bezel composited, no background mat. `bezel` defaults to
// the settings' `withFrame`, so a picker that turns the frame off turns
// it off here too; passing `bezel` explicitly wins over both.
//
// The capture vocabulary is an ENHANCEMENT, not a hard dependency: on a
// page that doesn't load capture/*.js the recorder warns once and records
// exactly as it always did — natural composite size, bezel on, no resize.
// Requesting a size there is ignored rather than fatal.
//
// On Stop the compose canvas, rAF loop, and MediaRecorder are torn
// down; the only artifact that survives is the Blob URL for the
// download link.
(function () {
  'use strict';

  // Probed in order: MP4 plays everywhere natively, then WebM variants.
  // The first one MediaRecorder accepts wins; falling through to ''
  // lets the browser pick its own default.
  const PREFERRED_MIME_TYPES = [
    'video/mp4;codecs=avc1.42E01E',
    'video/webm;codecs=vp9',
    'video/webm;codecs=vp8',
    'video/webm',
  ];

  // Last-resort composite size: neither a decoded bezel nor a painted
  // source canvas to measure yet. An iPhone-ish portrait canvas keeps
  // `captureStream` valid until the first frame lands, at which point the
  // plan is recomputed against the real source (see `_paint`).
  const FALLBACK_SIZE = { width: 1170, height: 2532 };

  function pickMimeType() {
    if (typeof window.MediaRecorder === 'undefined') return '';
    const MR = window.MediaRecorder;
    for (const m of PREFERRED_MIME_TYPES) {
      if (MR.isTypeSupported && MR.isTypeSupported(m)) return m;
    }
    return '';
  }

  function extFor(mime) {
    return mime && mime.startsWith('video/mp4') ? 'mp4' : 'webm';
  }

  let warnedAboutVocabulary = false;

  /// The shared capture vocabulary, resolved late so recorder.js can be
  /// loaded in any order relative to capture/*.js — and `null` (with one
  /// warning for the whole page) when the page doesn't load it at all.
  function vocabulary() {
    const ns = window.Baguette || {};
    if (ns._CaptureSize && ns._CaptureSettings && ns._CaptureComposer) return ns;
    if (!warnedAboutVocabulary) {
      warnedAboutVocabulary = true;
      const log = window.console;
      if (log && log.warn) {
        log.warn(
          'BrowserRecorder: capture/capture-size.js, capture/capture-settings.js '
          + 'and capture/capture-composer.js are not loaded — recording at the '
          + 'natural composite size; output-size options are ignored.'
        );
      }
    }
    return null;
  }

  // The composite painter used when the capture vocabulary isn't on the
  // page. Same static surface as CaptureComposer so `_paint` stays one
  // code path; it just can't do anything but 1:1. Delete on sight once
  // every page carries the capture scripts.
  const NativeComposer = {
    compositeSize(frameImg, screen, sourceCanvas) {
      if (frameImg && frameImg.naturalWidth > 0 && screen && screen.viewport) {
        return { width: screen.viewport.width, height: screen.viewport.height };
      }
      if (sourceCanvas && sourceCanvas.width > 0) {
        return { width: sourceCanvas.width, height: sourceCanvas.height };
      }
      return { width: 0, height: 0 };
    },

    // The degraded path never supersamples — it exists to keep recording
    // working on a page that didn't load the capture scripts, not to
    // reproduce CaptureComposer's geometry.
    composite(frameImg, screen, sourceCanvas) {
      return { ...NativeComposer.compositeSize(frameImg, screen, sourceCanvas), scale: 1 };
    },

    paintComposite(ctx, { frameImg, screen, sourceCanvas, onOverlay }) {
      const useBezel = frameImg && frameImg.naturalWidth > 0
        && screen && screen.viewport && screen.rect;
      // Record pressed before the stream's first decoded frame is
      // ordinary; the bezel is already loaded and worth painting on its
      // own. Mirrors CaptureComposer.paintComposite exactly.
      const hasContent = !!sourceCanvas && sourceCanvas.width > 0;
      if (!useBezel && !hasContent) return;
      if (!useBezel) {
        const rect = {
          x: 0, y: 0, width: sourceCanvas.width, height: sourceCanvas.height,
        };
        ctx.drawImage(sourceCanvas, rect.x, rect.y, rect.width, rect.height);
        if (onOverlay) onOverlay(ctx, rect);
        return;
      }
      // Bezel under, screen over: DeviceKit composites paint opaque dark
      // "off glass" inside the cutout, authored to sit UNDER live content.
      const vp = screen.viewport;
      const rect = screen.rect;
      ctx.drawImage(frameImg, 0, 0, vp.width, vp.height);
      if (!hasContent) return;
      ctx.save();
      NativeComposer.roundRectPath(
        ctx, rect.x, rect.y, rect.width, rect.height, screen.clipRadius || 0
      );
      ctx.clip();
      ctx.drawImage(sourceCanvas, rect.x, rect.y, rect.width, rect.height);
      if (onOverlay) onOverlay(ctx, rect);
      ctx.restore();
    },

    compose(ctx, plan, background, paint) {
      ctx.clearRect(0, 0, plan.width, plan.height);
      if (background && background !== 'transparent') {
        ctx.fillStyle = background;
        ctx.fillRect(0, 0, plan.width, plan.height);
      }
      if (!(plan.drawW > 0) || !(plan.drawH > 0)) return;
      if (!(plan.sourceWidth > 0) || !(plan.sourceHeight > 0)) return;
      ctx.save();
      ctx.translate(plan.drawX, plan.drawY);
      ctx.scale(plan.drawW / plan.sourceWidth, plan.drawH / plan.sourceHeight);
      paint(ctx);
      ctx.restore();
    },

    roundRectPath(ctx, x, y, w, h, r) {
      ctx.beginPath();
      ctx.moveTo(x + r, y);
      ctx.lineTo(x + w - r, y);
      ctx.quadraticCurveTo(x + w, y, x + w, y + r);
      ctx.lineTo(x + w, y + h - r);
      ctx.quadraticCurveTo(x + w, y + h, x + w - r, y + h);
      ctx.lineTo(x + r, y + h);
      ctx.quadraticCurveTo(x, y + h, x, y + h - r);
      ctx.lineTo(x, y + r);
      ctx.quadraticCurveTo(x, y, x + r, y);
      ctx.closePath();
    },
  };

  /// The no-vocabulary plan: the source fills the canvas, exactly as the
  /// recorder behaved before capture sizes existed. `locked` is the frozen
  /// canvas size once one exists, so a source that reconfigures mid-take
  /// keeps filling the same box.
  function nativePlan(natural, locked) {
    const width  = (locked && locked.width)  || natural.width;
    const height = (locked && locked.height) || natural.height;
    return {
      width,
      height,
      drawX: 0,
      drawY: 0,
      drawW: width,
      drawH: height,
      sourceWidth: natural.width,
      sourceHeight: natural.height,
    };
  }

  class BrowserRecorder {
    constructor(opts) {
      const o = opts || {};
      this.sourceCanvas = o.canvas;
      this.frameImg    = o.frameImg    || null;
      this.screen      = o.screen      || null;     // SDK SimulatorDefinition.screen
      this.overlayHost = o.overlayHost || null;
      this.fps         = o.fps || 60;
      // Visible-quality knob. Default 12 Mbps — well above the browser's
      // built-in (~2.5 Mbps) without exploding file size; H.264 at this
      // bitrate is artifact-free for an iPhone-sized canvas. Override via
      // `bitrate` for archive-grade or transport-sized recordings.
      this.bitrate     = o.bitrate || 12_000_000;

      // Sizing inputs are kept raw and resolved in `start()` — building a
      // CaptureSettings here would force capture/*.js to be loaded before
      // recorder.js, and an idle recorder is meant to hold nothing.
      this._settingsOpt = o.settings || null;
      this._sizeOpt     = o.captureSize;
      this._fitOpt      = o.fit;
      this._bgOpt       = o.background;
      this._bezelOpt    = o.bezel;

      this.settings = null;          // null when capture/*.js isn't loaded
      this.bezel = true;
      this.plan = null;
      this.background = 'transparent';
      this.mimeType = pickMimeType();
      this.compose = null;
      this.composeCtx = null;
      this.rafId = null;
      this.recorder = null;
      this.chunks = [];
      this.startedAt = 0;
      this.endedAt = 0;
      this._composer = NativeComposer;
      this._lockedSize = null;       // a fixed CaptureSize, when resizable
      this._locked = null;           // the frozen canvas dimensions
    }

    /// True iff `MediaRecorder` exists. Older browsers (or strict CSP
    /// configs without MediaRecorder) hide the Record button entirely.
    /// The capture vocabulary is deliberately NOT part of this — without
    /// it recording still works, it just can't be resized.
    static isAvailable() {
      return typeof window.MediaRecorder !== 'undefined';
    }

    start() {
      if (!this.sourceCanvas) throw new Error('canvas is required');
      if (!BrowserRecorder.isAvailable()) {
        throw new Error('MediaRecorder not available in this browser');
      }
      const vocab = vocabulary();
      this._composer = vocab ? vocab._CaptureComposer : NativeComposer;
      this._resolveSettings(vocab);

      // The compose canvas is the recording's full output — captureStream
      // samples it at fps. Its size is whatever the picked CaptureSize
      // resolves the natural composite to.
      const natural = this._composite();
      this.plan = this.settings
        ? this.settings.plan(natural.width, natural.height)
        : nativePlan(natural, null);
      this.background = this.settings ? this.settings.effectiveBackground : 'transparent';

      this.compose = window.document.createElement('canvas');
      this.compose.width  = this.plan.width;
      this.compose.height = this.plan.height;
      this.composeCtx = this.compose.getContext('2d');
      // High-quality scaling matters when the live stream is below the
      // bezel composite's native resolution (e.g. scale=2 or scale=3 in
      // the streaming sidebar). Default `'low'` produces visible nearest-
      // neighbour stair-stepping; `'high'` invokes the browser's better
      // resampler (Lanczos / bicubic depending on engine).
      this.composeCtx.imageSmoothingEnabled = true;
      this.composeCtx.imageSmoothingQuality = 'high';

      // The output size is LOCKED for the whole recording: `captureStream`
      // binds to this canvas' backing store, and resizing it mid-flight
      // either tears the video track down or hands the encoder a frame
      // size it already committed to. The stream can still reconfigure its
      // scale underneath us, so later frames are re-planned against this
      // frozen box and letterboxed into it rather than growing the canvas
      // — see `_paint`.
      this._locked = { width: this.plan.width, height: this.plan.height };
      this._lockedSize = vocab
        ? vocab._CaptureSize.parse(`${this.plan.width}x${this.plan.height}`)
        : null;

      this._startPaintLoop();

      // A MediaRecorder that refuses the stream (unsupported mime, a
      // canvas the compositor won't capture) must not leave the paint
      // loop running forever against an orphaned canvas — callers catch
      // `start()` and show an error, they don't call `cancel()`.
      try {
        const stream = this.compose.captureStream(this.fps);
        const recorderOpts = {};
        if (this.mimeType) recorderOpts.mimeType = this.mimeType;
        if (this.bitrate)  recorderOpts.videoBitsPerSecond = this.bitrate;
        this.recorder = new window.MediaRecorder(stream, recorderOpts);
        this.recorder.ondataavailable = (e) => {
          if (e.data && e.data.size > 0) this.chunks.push(e.data);
        };
        this.recorder.start(1000);
      } catch (err) {
        this._teardown();
        throw err;
      }
      this.startedAt = Date.now();
    }

    /// Fold the loose sizing options down to one CaptureSettings, then
    /// settle whether the device frame is composited in. Without the
    /// vocabulary there are no settings — `bezel` still applies, since
    /// that's the recorder's own knob.
    _resolveSettings(vocab) {
      if (!vocab) {
        this.settings = null;
        this.bezel = this._bezelOpt === undefined ? true : !!this._bezelOpt;
        return;
      }
      if (this._settingsOpt) {
        this.settings = this._settingsOpt;
      } else {
        const size = this._sizeOpt && this._sizeOpt.spec
          ? this._sizeOpt.spec
          : this._sizeOpt;
        this.settings = new vocab._CaptureSettings({
          size,
          fit: this._fitOpt,
          background: this._bgOpt,
        });
      }
      this.bezel = this._bezelOpt === undefined
        ? this.settings.withFrame
        : !!this._bezelOpt;
    }

    /// The composite's own size, before any target size is applied. With
    /// the bezel on that's the frame's viewport; with it off — a 3D view,
    /// whose server-rendered canvas already contains the device body — the
    /// source canvas is the whole picture.
    _composite() {
      const c = this._composer.composite(
        this.bezel ? this.frameImg : null,
        this.bezel ? this.screen : null,
        this.sourceCanvas
      );
      return c.width > 0 && c.height > 0 ? c : { ...FALLBACK_SIZE, scale: 1 };
    }

    _startPaintLoop() {
      const tick = () => {
        this._paint();
        this.rafId = window.requestAnimationFrame(tick);
      };
      this.rafId = window.requestAnimationFrame(tick);
    }

    // Per-frame paint, all of it delegated to the composer: background,
    // then bezel → screen (clipped) → pinch dots, placed into the locked
    // output box. ~1 ms on Apple Silicon for an iPhone-sized composite.
    _paint() {
      // `stop()` awaits the recorder's own `onstop`, so a frame already
      // scheduled by the paint loop can land after teardown has nulled the
      // compose canvas. Nothing left to paint onto — drop the frame.
      if (!this.composeCtx || !this.plan) return;

      const natural = this._composite();
      if (natural.width !== this.plan.sourceWidth
        || natural.height !== this.plan.sourceHeight) {
        // The source reconfigured mid-recording. Re-plan against the
        // frozen output box so the new frames land in the size the
        // encoder is already committed to.
        this.plan = this._lockedSize
          ? this._lockedSize.plan(natural.width, natural.height, this.settings.fit)
          : nativePlan(natural, this._locked);
      }

      this._composer.compose(this.composeCtx, this.plan, this.background, (ctx) => {
        // `compose` set the transform for a source the size of the grown
        // composite; `paintComposite` paints at the bezel's own size, so
        // the supersample factor goes on here.
        if (natural.scale !== 1) ctx.scale(natural.scale, natural.scale);
        this._composer.paintComposite(ctx, {
          frameImg: this.bezel ? this.frameImg : null,
          screen: this.bezel ? this.screen : null,
          sourceCanvas: this.sourceCanvas,
          onOverlay: (c, rect) => this._paintOverlayDots(c, rect),
        });
      });
    }

    // Reads the current DOM positions of PinchOverlay's dots and paints
    // matching circles onto the compose canvas. PinchOverlay positions
    // its children at host-local pixels; we map those back to composite
    // coords using the host's bounding box. No state cached anywhere —
    // each tick re-reads what the live overlay is showing.
    _paintOverlayDots(ctx, screenRect) {
      const host = this.overlayHost;
      if (!host || host.children.length === 0) return;
      const hostRect = host.getBoundingClientRect();
      if (hostRect.width === 0 || hostRect.height === 0) return;
      const sx = screenRect.width  / hostRect.width;
      const sy = screenRect.height / hostRect.height;

      // PinchOverlay dot styling (sim-input.js): 36px diameter, indigo
      // fill+stroke, soft shadow. Mirror it on the canvas — same look,
      // no shadow (Canvas2D shadows are slow and the recording doesn't
      // need them to read clearly).
      const radiusComposite = 18 * Math.max(sx, sy);   // matches DOM 36px diameter
      ctx.save();
      ctx.fillStyle   = 'rgba(99, 102, 241, 0.35)';
      ctx.strokeStyle = 'rgba(99, 102, 241, 0.9)';
      ctx.lineWidth   = 2 * Math.max(sx, sy);
      for (const dot of host.children) {
        const left = parseFloat(dot.style.left);
        const top  = parseFloat(dot.style.top);
        if (!isFinite(left) || !isFinite(top)) continue;
        const cx = screenRect.x + left * sx;
        const cy = screenRect.y + top  * sy;
        ctx.beginPath();
        ctx.arc(cx, cy, radiusComposite, 0, Math.PI * 2);
        ctx.fill();
        ctx.stroke();
      }
      ctx.restore();
    }

    /// Stop the recorder, await the final chunk, return an artifact ready
    /// to drop into a `<a download>` link. The Blob URL stays valid for
    /// the life of the page; callers free it via URL.revokeObjectURL when
    /// they're done with the link.
    async stop() {
      if (!this.recorder) throw new Error('not started');
      const recorder = this.recorder;
      const stopped = new Promise((resolve) => { recorder.onstop = resolve; });
      try { recorder.requestData(); } catch { /* not all impls expose this */ }
      recorder.stop();
      await stopped;
      this.endedAt = Date.now();
      const plan = this.plan || { width: 0, height: 0 };
      const settings = this.settings;
      this._teardown();

      const blob = new window.Blob(this.chunks, { type: this.mimeType || 'video/webm' });
      this.chunks = [];
      const stamp = new Date(this.startedAt)
        .toISOString().replace(/[:.]/g, '-').replace('Z', '');
      // `slug` names the size the file actually came out at, so a folder
      // of exports sorts by device-size at a glance:
      //   simulator-2026-…-appstore-6.9-1290x2796.mp4
      // CaptureSettings.slug is the one place that policy lives (including
      // keeping a ratio spec like `16:9` filename-safe), shared with
      // screenshots — without it we can only name the dimensions.
      const slug = settings
        ? settings.slug(plan.width, plan.height)
        : `${Math.round(plan.width)}x${Math.round(plan.height)}`;
      return {
        blob,
        url: window.URL.createObjectURL(blob),
        filename: `simulator-${stamp}-${slug}.${extFor(this.mimeType)}`,
        mimeType: this.mimeType,
        durationSeconds: (this.endedAt - this.startedAt) / 1000,
        bytes: blob.size,
      };
    }

    /// Discard the in-flight recording. Used when the live stream
    /// disconnects mid-record or the user navigates away.
    cancel() {
      if (this.recorder && this.recorder.state !== 'inactive') {
        try { this.recorder.stop(); } catch { /* ignore */ }
      }
      this._teardown();
      this.chunks = [];
    }

    _teardown() {
      if (this.rafId) {
        window.cancelAnimationFrame(this.rafId);
        this.rafId = null;
      }
      this.recorder = null;
      this.compose = null;
      this.composeCtx = null;
      this._lockedSize = null;
      this._locked = null;
    }
  }

  window.BrowserRecorder = BrowserRecorder;
})();
