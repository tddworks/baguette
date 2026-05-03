// BrowserRecorder — record the live view (bezel + screen + pinch HUD)
// to a WebM/MP4 file. Spins up a compose canvas only while recording;
// idles cost zero. Reuses what's already in the page:
//
//   • frameImg     — the bezel <img> DeviceFrame already loaded
//   • layout       — the chrome.json layout already fetched
//   • sourceCanvas — the live decoded canvas StreamSession is painting
//   • overlayHost  — PinchOverlay's DOM container (we read positions
//                    out of it each frame, no caching)
//
// On Stop the compose canvas, rAF loop, and MediaRecorder are torn
// down; the only artifact that survives is the Blob URL for the
// download link.
//
//   const rec = new BrowserRecorder({
//     canvas, frameImg, layout, overlayHost, fps: 60,
//   });
//   rec.start();
//   const artifact = await rec.stop();
//   //   { url, blob, filename, mimeType, durationSeconds, bytes }
//   rec.cancel();
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

  function pickMimeType() {
    if (typeof MediaRecorder === 'undefined') return '';
    for (const m of PREFERRED_MIME_TYPES) {
      if (MediaRecorder.isTypeSupported && MediaRecorder.isTypeSupported(m)) return m;
    }
    return '';
  }

  function extFor(mime) {
    return mime && mime.startsWith('video/mp4') ? 'mp4' : 'webm';
  }

  function BrowserRecorder(opts) {
    opts = opts || {};
    this.sourceCanvas = opts.canvas;
    this.frameImg    = opts.frameImg    || null;
    this.layout      = opts.layout      || null;
    this.overlayHost = opts.overlayHost || null;
    this.fps         = opts.fps || 60;
    // Visible-quality knob. Default 12 Mbps — well above the browser's
    // built-in (~2.5 Mbps) without exploding file size; H.264 at this
    // bitrate is artifact-free for an iPhone-sized canvas. Override via
    // `bitrate` for archive-grade or transport-sized recordings.
    this.bitrate     = opts.bitrate || 12_000_000;

    this.mimeType = pickMimeType();
    this.compose = null;
    this.composeCtx = null;
    this.rafId = null;
    this.recorder = null;
    this.chunks = [];
    this.startedAt = 0;
    this.endedAt = 0;
  }

  /// True iff `MediaRecorder` exists. Older browsers (or strict CSP
  /// configs without MediaRecorder) hide the Record button entirely.
  BrowserRecorder.isAvailable = function () {
    return typeof MediaRecorder !== 'undefined';
  };

  BrowserRecorder.prototype.start = function () {
    if (!this.sourceCanvas) throw new Error('canvas is required');
    if (!BrowserRecorder.isAvailable()) {
      throw new Error('MediaRecorder not available in this browser');
    }

    // Compose canvas size: bezel composite when available, source-canvas
    // size otherwise. The compose canvas is the recording's full output
    // — captureStream samples it at fps.
    const size = composeSize(this.frameImg, this.layout, this.sourceCanvas);
    this.compose = document.createElement('canvas');
    this.compose.width  = size.w;
    this.compose.height = size.h;
    this.composeCtx = this.compose.getContext('2d');
    // High-quality scaling matters when the live stream is below the
    // bezel composite's native resolution (e.g. scale=2 or scale=3 in
    // the streaming sidebar). Default `'low'` produces visible nearest-
    // neighbour stair-stepping; `'high'` invokes the browser's better
    // resampler (Lanczos / bicubic depending on engine).
    this.composeCtx.imageSmoothingEnabled = true;
    this.composeCtx.imageSmoothingQuality = 'high';

    this._startPaintLoop();

    const stream = this.compose.captureStream(this.fps);
    const recorderOpts = {};
    if (this.mimeType) recorderOpts.mimeType = this.mimeType;
    if (this.bitrate)  recorderOpts.videoBitsPerSecond = this.bitrate;
    this.recorder = new MediaRecorder(stream, recorderOpts);
    this.recorder.ondataavailable = (e) => {
      if (e.data && e.data.size > 0) this.chunks.push(e.data);
    };
    this.recorder.start(1000);
    this.startedAt = Date.now();
  };

  BrowserRecorder.prototype._startPaintLoop = function () {
    const tick = () => {
      this._paint();
      this.rafId = requestAnimationFrame(tick);
    };
    this.rafId = requestAnimationFrame(tick);
  };

  // Per-frame paint: bezel → screen (clipped) → pinch dots. Each layer
  // is drawn from data already on the page; nothing is fetched or
  // computed beyond the clip path. ~1 ms on Apple Silicon for an iPhone-
  // sized composite.
  BrowserRecorder.prototype._paint = function () {
    const ctx = this.composeCtx;
    const cw = this.compose.width;
    const ch = this.compose.height;
    ctx.clearRect(0, 0, cw, ch);

    const useBezel = this.frameImg && this.frameImg.naturalWidth > 0
                  && this.layout && this.layout.composite && this.layout.screen;

    if (useBezel) {
      const s = this.layout.screen;
      const r = this.layout.innerCornerRadius || 0;

      // 1. Bezel as background. DeviceKit composites render the screen
      //    area as opaque dark "off" glass meant to sit UNDER the live
      //    screen — so bezel goes first, screen on top.
      ctx.drawImage(this.frameImg, 0, 0, cw, ch);

      // 2. Screen content, clipped to the inner corner radius so the
      //    rounded screen corners match the bezel cutout exactly.
      if (this.sourceCanvas.width > 0) {
        ctx.save();
        roundRectPath(ctx, s.x, s.y, s.width, s.height, r);
        ctx.clip();
        ctx.drawImage(this.sourceCanvas, s.x, s.y, s.width, s.height);
        // 3. Pinch HUD on top, still inside the clip so dots near the
        //    rounded corners get cropped naturally.
        this._paintOverlayDots(ctx, s);
        ctx.restore();
      }
    } else if (this.sourceCanvas.width > 0) {
      // No bezel layout — fall through to bare-screen recording.
      ctx.drawImage(this.sourceCanvas, 0, 0, cw, ch);
      this._paintOverlayDots(ctx, { x: 0, y: 0, width: cw, height: ch });
    }
  };

  // Reads the current DOM positions of PinchOverlay's dots and paints
  // matching circles onto the compose canvas. PinchOverlay positions
  // its children at host-local pixels; we map those back to composite
  // coords using the host's bounding box. No state cached anywhere —
  // each tick re-reads what the live overlay is showing.
  BrowserRecorder.prototype._paintOverlayDots = function (ctx, screenRect) {
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
  };

  /// Stop the recorder, await the final chunk, return an artifact ready
  /// to drop into a `<a download>` link. The Blob URL stays valid for
  /// the life of the page; callers free it via URL.revokeObjectURL when
  /// they're done with the link.
  BrowserRecorder.prototype.stop = async function () {
    if (!this.recorder) throw new Error('not started');
    const recorder = this.recorder;
    const stopped = new Promise((resolve) => { recorder.onstop = resolve; });
    try { recorder.requestData(); } catch { /* not all impls expose this */ }
    recorder.stop();
    await stopped;
    this.endedAt = Date.now();
    if (this.rafId) { cancelAnimationFrame(this.rafId); this.rafId = null; }
    this.recorder = null;
    this.compose = null;
    this.composeCtx = null;

    const blob = new Blob(this.chunks, { type: this.mimeType || 'video/webm' });
    this.chunks = [];
    const stamp = new Date(this.startedAt)
      .toISOString().replace(/[:.]/g, '-').replace('Z', '');
    return {
      blob,
      url: URL.createObjectURL(blob),
      filename: `simulator-${stamp}.${extFor(this.mimeType)}`,
      mimeType: this.mimeType,
      durationSeconds: (this.endedAt - this.startedAt) / 1000,
      bytes: blob.size,
    };
  };

  /// Discard the in-flight recording. Used when the live stream
  /// disconnects mid-record or the user navigates away.
  BrowserRecorder.prototype.cancel = function () {
    if (this.recorder && this.recorder.state !== 'inactive') {
      try { this.recorder.stop(); } catch { /* ignore */ }
    }
    if (this.rafId) { cancelAnimationFrame(this.rafId); this.rafId = null; }
    this.recorder = null;
    this.compose = null;
    this.composeCtx = null;
    this.chunks = [];
  };

  // ── helpers ──────────────────────────────────────────────────

  function composeSize(frameImg, layout, sourceCanvas) {
    if (frameImg && frameImg.naturalWidth > 0 && layout && layout.composite) {
      return { w: layout.composite.width, h: layout.composite.height };
    }
    if (sourceCanvas && sourceCanvas.width > 0) {
      return { w: sourceCanvas.width, h: sourceCanvas.height };
    }
    return { w: 1170, h: 2532 };
  }

  function roundRectPath(ctx, x, y, w, h, r) {
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
  }

  window.BrowserRecorder = BrowserRecorder;
})();
