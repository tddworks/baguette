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
    // Live mirror — shown in the grid host while the canvas is moved
    // into the focus pane. Sourced from canvas.captureStream() so it
    // tracks every frame the decoder paints, with one decoder/socket
    // total. Lazy-initialized in `ensureMirrorStream()` because
    // captureStream() needs at least one painted frame to produce a
    // useful track.
    this.mirror = document.createElement('video');
    this.mirror.muted = true;
    this.mirror.autoplay = true;
    this.mirror.playsInline = true;
    this.mirror.style.cssText = 'position:absolute;inset:0;width:100%;height:100%;object-fit:contain;background:#000';
    this._mirrorStreamReady = false;
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
    this.pinchOverlay = null;    // visual HUD shown during 2-finger gestures
    this.inputLayout = null;     // chrome layout snapshot for sizing
  }

  // Move the canvas into whichever screen-host element the latest view
  // produced for this udid. If the device is not booted, we leave the
  // host empty — its overlay (BOOTING / SHUTDOWN / etc.) shows through.
  FarmTile.prototype.attach = function (host, opts) {
    this._mountIn(host, opts, this.canvas, /* fitObject */ 'fill');
  };

  // Install the live <video> mirror in `host` instead of the canvas —
  // used by FarmApp for the grid tile while the device is focused
  // (canvas is in the focus pane). Same DeviceFrame scaffolding so
  // bezel mode looks identical across the grid and focus pane.
  FarmTile.prototype.attachMirror = function (host, opts) {
    this.ensureMirrorStream();
    this._mountIn(host, opts, this.mirror, /* fitObject */ 'fill');
  };

  // Shared mount path. `useBezel` swaps the wrapper: when true, the
  // existing DeviceFrame builds the bezel <img> + screenArea + a fresh
  // canvas; we discard that canvas and graft the requested element
  // (canvas or video mirror) into the screenArea so the live pipeline
  // isn't disturbed. When false, the element sits raw inside the host
  // and edge-fills it.
  FarmTile.prototype._mountIn = function (host, opts, element, fitObject) {
    if (!host) return;
    const useBezel = !!(opts && opts.useBezel && window.DeviceFrame);
    const layout = opts && opts.layout || null;

    if (useBezel) {
      // Always rebuild — element identity may have changed (canvas ↔
      // mirror), or the layout may have arrived after a prior raw
      // mount. The DeviceFrame DOM is cheap; the live element is
      // re-grafted in place so the WebSocket / captureStream pipe
      // never sees a teardown.
      host.innerHTML = '';
      host.classList.add('with-bezel');
      const frame = new window.DeviceFrame({ udid: this.udid, layout });
      const surface = frame.mount(host);
      surface.canvas.replaceWith(element);
      element.style.cssText =
        `display:block;width:100%;height:100%;object-fit:${fitObject};background:#000`;
      host.dataset.bezelMounted = 'yes';
      return;
    }

    // Raw mode — strip any prior bezel scaffolding, drop the element in.
    if (host.dataset.bezelMounted === 'yes') {
      host.innerHTML = '';
      delete host.dataset.bezelMounted;
      host.classList.remove('with-bezel');
    }
    element.style.cssText =
      'position:absolute;inset:0;width:100%;height:100%;object-fit:contain;background:#000';
    if (element.parentElement !== host) host.appendChild(element);
  };

  // Wire the mirror video to the canvas's captureStream(). The track
  // doesn't yield frames until the canvas has painted at least once,
  // so this is called lazily on the first attachMirror() — by then
  // the StreamSession has been alive long enough to draw frames.
  FarmTile.prototype.ensureMirrorStream = function () {
    if (this._mirrorStreamReady) return;
    if (typeof this.canvas.captureStream !== 'function') return;
    try {
      this.mirror.srcObject = this.canvas.captureStream();
      this._mirrorStreamReady = true;
    } catch {
      // Older browsers / non-hardware-accelerated contexts: leave the
      // mirror dark. It's a UX nicety, not a correctness requirement.
    }
  };

  FarmTile.prototype.start = function () {
    if (this.session || this.device.uiState !== 'live') return;
    this.session = new window.StreamSession({
      udid:   this.udid,
      format: 'mjpeg',           // MJPEG decodes anywhere — H.264/AVCC needs WebCodecs.
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
      onLog:  () => {}
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
    const host = this.canvas.parentElement;
    if (!host) return;

    this.simInput = new window.SimInput({
      udid: this.udid,
      log:  () => {},
      transport: window.SimInputBridge.makeTransport(this.session)
    });
    this.simInput.setScreenSize(...this.computeScreenSize());

    // Overlay the same two-finger HUD sim-stream uses, so pinches /
    // ctrl+wheel / Safari-gesture pinches show their finger circles
    // on the focused canvas. The overlay attaches to the canvas's
    // parent (positioned context); MouseGestureSource pushes finger
    // points into it during touch streams.
    if (window.PinchOverlay) {
      this.pinchOverlay = new window.PinchOverlay(host);
    }

    // Attach to the canvas itself — the precise rectangle covering
    // live screen pixels in both raw and bezel modes. Mouse coords
    // normalize against the listener element, so canvas is the
    // right pick. `touch-action:none` and `cursor:crosshair` mirror
    // the affordances DeviceFrame puts on its screenArea.
    this.canvas.style.cursor = 'crosshair';
    this.canvas.style.touchAction = 'none';
    this.canvas.tabIndex = 0;
    this.mouseSource = new window.MouseGestureSource({
      el:    this.canvas,
      input: this.simInput,
      overlay: this.pinchOverlay,
      log:   () => {}
    });
    this.mouseSource.attach();
  };

  FarmTile.prototype.unwireInput = function () {
    if (this.mouseSource && typeof this.mouseSource.detach === 'function') {
      try { this.mouseSource.detach(); } catch {}
    }
    this.mouseSource = null;
    this.simInput = null;
    if (this.pinchOverlay && this.pinchOverlay.container?.parentElement) {
      this.pinchOverlay.container.parentElement.removeChild(this.pinchOverlay.container);
    }
    this.pinchOverlay = null;
    this.canvas.style.cursor = '';
    this.canvas.style.touchAction = '';
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
    if (this.session) { this.session.stop(); this.session = null; }
    this.mode = 'idle';
    if (this.canvas.parentElement) this.canvas.parentElement.removeChild(this.canvas);
  };

  window.FarmTile = FarmTile;
})();
