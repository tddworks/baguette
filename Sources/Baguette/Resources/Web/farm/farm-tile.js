// FarmTile — owns one device's StreamSession lifecycle and live
// canvas. Designed to survive view re-renders: the canvas is a single
// element that gets re-parented into whichever `[data-screen-host]`
// the current view emitted. That way switching Grid → Wall → List
// doesn't tear down the WebSocket and re-handshake N streams.
//
//   const tile = new FarmTile({
//     device,                    // { udid, name, runtime, state, platform, uiState }
//     onTelemetry: (udid, t) => …  // { fps } each second; updates readouts
//   });
//   tile.attach(host);            // host is a `[data-screen-host]` node
//   tile.start();                 // opens WS in thumbnail mode
//   tile.promote();               // bumps to full quality (focused)
//   tile.demote();                // back to thumbnail
//   tile.stop();                  // closes WS, releases canvas
//
// Thumbnail config: 8 fps, scale divisor 4 (quarter res), ~600 kbps.
// Full config: 60 fps, scale 1, 6 Mbps. Both ride the existing
// `set_fps` / `set_scale` / `set_bitrate` reconfig protocol on the
// per-device WS — no new server endpoints required.
(function () {
  'use strict';

  const THUMB = { fps: 8,  scale: 4, bps: 600_000 };
  const FULL  = { fps: 60, scale: 1, bps: 6_000_000 };

  function FarmTile(opts) {
    this.device = opts.device;
    this.udid   = opts.device.udid;
    this.onTelemetry = opts.onTelemetry || (() => {});
    this.onSize      = opts.onSize      || (() => {});
    this.canvas = document.createElement('canvas');
    this.canvas.style.cssText = 'width:100%;height:100%;display:block;background:#000';
    // Live mirror — a second canvas that's redrawn from `this.canvas`
    // on every animation frame. Used by the focus pane while a tile
    // is selected, so we can keep the source canvas painting in its
    // grid host (selection no longer reparents anything in the grid).
    //
    // Why a canvas-copy and not `captureStream() → <video>`? In
    // practice captureStream is fragile across browsers — the
    // produced track sometimes stalls even though the source canvas
    // keeps drawing, and any failure is silent (just black). A
    // straight `drawImage(src, 0, 0)` per rAF is deterministic, has
    // no autoplay/codec edge cases, and costs one bitmap blit.
    this.mirror = document.createElement('canvas');
    this.mirror.style.cssText = 'width:100%;height:100%;display:block;background:#000';
    this._mirrorRaf = null;
    this.session = null;
    this.mode = 'idle';   // 'idle' | 'thumb' | 'full'
    this.lastFps = 0;
    // Frame-reported size in pixels; updated on every onSize callback.
    // Used as the input-plane fallback when there's no chrome layout.
    this.framePixelSize = { w: 0, h: 0 };
    // Input plumbing — only attached while this tile is the focused
    // device (FarmApp calls promote() / demote()). Each holds onto its
    // detach handle so the same tile can re-promote without leaks.
    this.simInput = null;
    this.mouseSource = null;
    this.keyboardCapture = null;
    this.pinchOverlay = null;    // visual HUD shown during 2-finger gestures
    this.inputLayout = null;     // chrome layout snapshot for sizing
  }

  // Move the canvas into whichever screen-host element the latest view
  // produced for this udid. If the device is not booted, we leave the
  // host empty — its overlay (BOOTING / SHUTDOWN / etc.) shows through.
  FarmTile.prototype.attach = function (host, opts) {
    this._mountIn(host, opts, this.canvas, /* fitObject */ 'fill');
  };

  // Install the live mirror canvas in `host` (the focus preview) —
  // used by FarmApp while a tile is focused. The source canvas
  // stays in its grid host the whole time; `_startMirrorCopy()`
  // drives a per-frame redraw of the source into the mirror so the
  // focus pane shows live frames.
  FarmTile.prototype.attachMirror = function (host, opts) {
    this._mountIn(host, opts, this.mirror, /* fitObject */ 'fill');
    this._startMirrorCopy();
  };

  // Detach the mirror from any host and stop the copy loop. Called by
  // FarmFocus.dispose() (or implicitly when the tile is destroyed).
  FarmTile.prototype.detachMirror = function () {
    this._stopMirrorCopy();
    if (this.mirror.parentElement) {
      this.mirror.parentElement.removeChild(this.mirror);
    }
  };

  FarmTile.prototype._startMirrorCopy = function () {
    if (this._mirrorRaf) return;
    const src = this.canvas;
    const dst = this.mirror;
    const ctx = dst.getContext('2d');
    const loop = () => {
      // Track source dimensions — StreamSession resizes the source
      // when frame size changes (e.g. on reconfig). drawImage scales
      // automatically, but matching dimensions avoids quality loss.
      if (src.width > 0 && src.height > 0) {
        if (dst.width !== src.width || dst.height !== src.height) {
          dst.width = src.width;
          dst.height = src.height;
        }
        try { ctx.drawImage(src, 0, 0); } catch {}
      }
      this._mirrorRaf = requestAnimationFrame(loop);
    };
    this._mirrorRaf = requestAnimationFrame(loop);
  };

  FarmTile.prototype._stopMirrorCopy = function () {
    if (this._mirrorRaf) {
      cancelAnimationFrame(this._mirrorRaf);
      this._mirrorRaf = null;
    }
  };

  // Shared mount path. `useBezel` swaps the wrapper: when true, the
  // existing DeviceFrame builds the bezel <img> + screenArea + a fresh
  // canvas; we discard that canvas and graft the requested element
  // (canvas or video mirror) into the screenArea so the live pipeline
  // isn't disturbed. When false, the element sits raw inside the host
  // and edge-fills it.
  //
  // Idempotency matters: FarmApp.renderAll() runs on every filter or
  // telemetry change, and detaching a `<video>` from the DOM (even
  // momentarily) pauses it on most browsers. We early-return when the
  // live element is already grafted into this host with the same
  // bezel mode, so the mirror stream keeps running smoothly.
  FarmTile.prototype._mountIn = function (host, opts, element, fitObject) {
    if (!host) return;
    const useBezel = !!(opts && opts.useBezel && window.DeviceFrame);
    const layout = opts && opts.layout || null;

    if (useBezel) {
      // Already mounted in this host with the right element + mode? Skip.
      if (host.dataset.bezelMounted === 'yes' &&
          host.dataset.activeKind === element.tagName &&
          host.contains(element)) {
        return;
      }
      host.innerHTML = '';
      host.classList.add('with-bezel');
      const frame = new window.DeviceFrame({ udid: this.udid, layout });
      const surface = frame.mount(host);
      surface.canvas.replaceWith(element);
      element.style.cssText =
        `display:block;width:100%;height:100%;object-fit:${fitObject};background:#000`;
      // DeviceFrame sets the wrapper inline to `display:inline-block;
      // max-height:70vh` (sized for the single-device page). In the
      // farm grid the wrapper sits inside a fixed-height tile; the
      // image inside has `height: 100%` and `width: auto`, which —
      // combined with `max-width: 100%` clipping the wrapper to the
      // column width — leaves the wrapper at the column box but the
      // image overflowing or letterboxed inside it. screenArea uses
      // percentages of the *wrapper*, so its rendered rectangle drifts
      // from the bezel's actual screen rect. Canvas with object-fit:
      // fill stretches to that drifted rectangle (most visible on
      // squarish devices like Apple Watch).
      //
      // Fix: size the wrapper in explicit pixels matching the
      // composite's aspect ratio. We compute a fit-inside box of
      // (host.width, host.height) that preserves the composite ratio,
      // then pin wrapper.width/height to those numbers. The image at
      // height:100%; width:auto then renders to exactly the wrapper
      // bounds, screenArea percentages map onto the real bezel hole,
      // and the canvas fills the device's true screen aspect.
      const wrapper = host.firstElementChild;
      const bezelImg = wrapper && wrapper.querySelector('img');
      // DeviceFrame's inline style includes `max-height: 70vh` for the
      // single-device page where the host is otherwise unconstrained.
      // In the farm the wrapper carries explicit pixel dimensions, so
      // the 70vh fights the layout: when the viewport is shorter than
      // the wrapper, the image clamps below wrapper height, the screen
      // rect (% of wrapper) drifts off the bezel cutout. Override here.
      if (bezelImg) {
        bezelImg.style.maxHeight = '100%';
        bezelImg.style.maxWidth  = '100%';
      }
      if (wrapper && layout && layout.composite &&
          layout.composite.width && layout.composite.height) {
        const ratio = layout.composite.width / layout.composite.height;
        // Fit the wrapper inside the host while preserving the
        // composite's aspect ratio. Re-runs on host resize via the
        // ResizeObserver below so window zoom / focus-pane resize
        // keeps the bezel + screen rect aligned.
        const fit = () => {
          const r = host.getBoundingClientRect();
          const maxW = r.width  || host.clientWidth  || 232;
          const maxH = r.height || host.clientHeight || 320;
          let w = maxH * ratio, h = maxH;
          if (w > maxW) { w = maxW; h = maxW / ratio; }
          wrapper.style.width  = w + 'px';
          wrapper.style.height = h + 'px';
          wrapper.style.maxWidth  = 'none';
          wrapper.style.maxHeight = 'none';
        };
        fit();
        if (this._fitObserver) this._fitObserver.disconnect();
        if (typeof ResizeObserver !== 'undefined') {
          this._fitObserver = new ResizeObserver(fit);
          this._fitObserver.observe(host);
        }
      }
      host.dataset.bezelMounted = 'yes';
      host.dataset.activeKind = element.tagName;
      return;
    }

    // Raw mode — strip any prior bezel scaffolding or stale element
    // and drop the requested element in. Idempotent: when the
    // requested element is already the sole child, no-op.
    if (host.dataset.bezelMounted === 'yes') {
      host.innerHTML = '';
      delete host.dataset.bezelMounted;
      host.classList.remove('with-bezel');
    }
    if (host.firstChild !== element || host.children.length > 1) {
      host.innerHTML = '';
      host.appendChild(element);
      element.style.cssText =
        'position:absolute;inset:0;width:100%;height:100%;object-fit:contain;background:#000';
      host.dataset.activeKind = element.tagName;
    }
  };

  FarmTile.prototype.start = function () {
    if (this.session || this.device.uiState !== 'live') return;
    this.session = new window.StreamSession({
      udid:   this.udid,
      // MJPEG decodes anywhere — H.264/AVCC needs WebCodecs. The farm
      // runs N parallel streams (one per booted device); MJPEG keeps
      // the server out of the GPU's hardware-encoder budget, which
      // matters once N gets above ~5 on Apple Silicon. Recording is
      // browser-side now, so it doesn't need the AVCC NAL stream.
      format: 'mjpeg',
      version: 'v2',
      canvas: this.canvas,
      onSize: (w, h) => {
        this.framePixelSize = { w, h };
        // While focused, keep SimInput's screen size in sync with the
        // current frame — first-frame sizes the input plane; later
        // resizes (from `set_scale` switches between thumb and full)
        // re-anchor it without losing the active gesture state.
        if (this.simInput) this.simInput.setScreenSize(...this.computeScreenSize());
        this.onSize(this.udid, w, h);
      },
      onFps:  (fps) => {
        this.lastFps = fps;
        this.onTelemetry(this.udid, { fps });
      },
      onLog:  () => {},
    });
    this.session.start();
    this.mode = 'thumb';
    setTimeout(() => this.applyConfig(THUMB), 200);
  };

  // promote() upgrades stream quality AND wires gesture input. The
  // wiring requires the canvas to have a parent (so the mouse source
  // can attach to its bounding box) — FarmApp calls promote() after
  // the canvas has been attached to the focus preview, so by this
  // point `canvas.parentElement` is the element we want to listen on.
  FarmTile.prototype.promote = function (opts) {
    if (!this.session) { this.start(); }
    this.mode = 'full';
    this.applyConfig(FULL);
    this.inputLayout = (opts && opts.layout) || null;
    this.wireInput();
  };

  FarmTile.prototype.demote = function () {
    if (!this.session) return;
    this.mode = 'thumb';
    this.applyConfig(THUMB);
    this.unwireInput();
    // Stop the per-frame copy when the tile is no longer focused.
    // The mirror element stays in DOM until FarmFocus.dispose()
    // wipes the focus pane innerHTML; either way, no point burning
    // a rAF loop when nothing's looking at the mirror.
    this._stopMirrorCopy();
  };

  // ---- input lifecycle ------------------------------------------------
  // Resolve the input plane's logical size in device points. Order:
  //   1. cached chrome layout's `screen.{width,height}` — accurate
  //   2. last frame size from StreamSession.onSize — close enough at
  //      scale=1, off-by-divisor at thumbnail scales. Won't matter
  //      because FarmTile only wires input while in `full` mode.
  //   3. iPhone-15-Pro-ish default — keeps math from dividing by zero
  //      while the WS handshake completes.
  FarmTile.prototype.computeScreenSize = function () {
    if (this.inputLayout?.screen) {
      return [this.inputLayout.screen.width, this.inputLayout.screen.height];
    }
    if (this.framePixelSize.w > 0) {
      return [this.framePixelSize.w, this.framePixelSize.h];
    }
    return [402, 874];
  };

  FarmTile.prototype.wireInput = function () {
    if (this.simInput || !this.session || !window.SimInput) return;
    if (!window.SimInputBridge || !window.MouseGestureSource) return;
    // The mirror lives in the focus pane while focused — that's the
    // element the user sees and clicks. Mouse coords normalize against
    // the listener element's bounding box, so attaching to the mirror
    // (instead of the canvas, which stays in the grid) gives correct
    // device-point math out of the box.
    const target = this.mirror;
    const host = target.parentElement;
    if (!host) return;

    this.simInput = new window.SimInput({
      udid: this.udid,
      log:  () => {},
      transport: window.SimInputBridge.makeTransport(this.session)
    });
    this.simInput.setScreenSize(...this.computeScreenSize());

    if (window.PinchOverlay) {
      this.pinchOverlay = new window.PinchOverlay(host);
    }

    target.style.cursor = 'crosshair';
    target.style.touchAction = 'none';
    target.tabIndex = 0;
    this.mouseSource = new window.MouseGestureSource({
      el:    target,
      input: this.simInput,
      overlay: this.pinchOverlay,
      log:   () => {}
    });
    this.mouseSource.attach();

    // Mac keyboard → focused tile. Same focus-gated capture used by
    // sim-native: mousedown on the mirror takes focus; while focused,
    // every supported keystroke flows through `simInput.key`. Click
    // out (or focus another tile) → host browser shortcuts work again.
    if (window.KeyboardCapture) {
      target.addEventListener('mousedown', () => target.focus());
      this.keyboardCapture = new window.KeyboardCapture({
        target,
        simInput: () => this.simInput,
      });
      this.keyboardCapture.start();
    }
  };

  FarmTile.prototype.unwireInput = function () {
    if (this.mouseSource && typeof this.mouseSource.detach === 'function') {
      try { this.mouseSource.detach(); } catch {}
    }
    this.mouseSource = null;
    if (this.keyboardCapture && typeof this.keyboardCapture.stop === 'function') {
      try { this.keyboardCapture.stop(); } catch {}
    }
    this.keyboardCapture = null;
    this.simInput = null;
    if (this.pinchOverlay && this.pinchOverlay.container?.parentElement) {
      this.pinchOverlay.container.parentElement.removeChild(this.pinchOverlay.container);
    }
    this.pinchOverlay = null;
    this.mirror.style.cursor = '';
    this.mirror.style.touchAction = '';
  };

  // Forward sidebar buttons (home / lock / volume / siri) to the
  // focused device. FarmFocus calls these on its preset row clicks.
  FarmTile.prototype.button = function (name) { this.simInput?.button(name); };
  FarmTile.prototype.type   = function (text) { this.simInput?.type(text); };
  FarmTile.prototype.key    = function (code) { this.simInput?.key(code); };

  FarmTile.prototype.applyConfig = function (cfg) {
    if (!this.session || !this.session.send) return;
    this.session.send({ type: 'set_fps',     fps: cfg.fps });
    this.session.send({ type: 'set_scale',   scale: cfg.scale });
    this.session.send({ type: 'set_bitrate', bps: cfg.bps });
  };

  FarmTile.prototype.forceIdr  = function () { this.session?.send?.({ type: 'force_idr' }); };
  FarmTile.prototype.snapshot  = function () { this.session?.send?.({ type: 'snapshot' }); };

  FarmTile.prototype.stop = function () {
    this.unwireInput();
    this._stopMirrorCopy();
    if (this._fitObserver) { this._fitObserver.disconnect(); this._fitObserver = null; }
    if (this.session) { this.session.stop(); this.session = null; }
    this.mode = 'idle';
    if (this.canvas.parentElement) this.canvas.parentElement.removeChild(this.canvas);
    if (this.mirror.parentElement) this.mirror.parentElement.removeChild(this.mirror);
  };

  window.FarmTile = FarmTile;
})();
