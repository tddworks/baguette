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
    // Active Baguette Simulator instances, keyed by the host element
    // they were mounted into (grid host + focus host can both hold a
    // sim concurrently). Each owns its own bezel + button overlays +
    // screen + keyboard, all wired to this.session via the transport's
    // send closure.
    this._sims = new Map();
  }

  // Move the canvas into whichever screen-host element the latest view
  // produced for this udid. If the device is not booted, we leave the
  // host empty — its overlay (BOOTING / SHUTDOWN / etc.) shows through.
  // `input:false` keeps grid tiles non-interactive on the screen
  // surface so a click selects the tile instead of taping the device;
  // the bezel's button overlays stay clickable either way.
  FarmTile.prototype.attach = function (host, opts) {
    this._mountIn(host, { ...(opts || {}), input: false }, this.canvas, 'fill');
  };

  // Install the live mirror canvas in `host` (the focus preview) —
  // used by FarmApp while a tile is focused. The source canvas
  // stays in its grid host the whole time; `_startMirrorCopy()`
  // drives a per-frame redraw of the source into the mirror so the
  // focus pane shows live frames.
  FarmTile.prototype.attachMirror = function (host, opts) {
    this._mountIn(host, { ...(opts || {}), input: true }, this.mirror, 'fill');
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
  // Baguette SDK's Bezel part builds the bezel <img> + screenArea +
  // a fresh canvas from the device definition; we discard that canvas
  // and graft the requested element (live canvas or mirror) into the
  // screenArea so the live pipeline isn't disturbed. When false, the
  // element sits raw inside the host and edge-fills it.
  //
  // Idempotency matters: FarmApp.renderAll() runs on every filter or
  // telemetry change, and detaching a `<video>` from the DOM (even
  // momentarily) pauses it on most browsers. We early-return when the
  // live element is already grafted into this host with the same
  // bezel mode, so the mirror stream keeps running smoothly.
  FarmTile.prototype._mountIn = function (host, opts, element, fitObject) {
    if (!host) return;
    const def = (opts && opts.def) || null;          // SDK definition.json
    const screenDef = def && def.screen;
    const useBezel = !!(opts && opts.useBezel && def &&
                        window.Baguette && window.Baguette._Simulator);

    if (useBezel) {
      // Already mounted in this host with the right element + mode? Skip.
      if (host.dataset.bezelMounted === 'yes' &&
          host.dataset.activeKind === element.tagName &&
          host.contains(element)) {
        return;
      }
      host.innerHTML = '';
      host.classList.add('with-bezel');
      // Tear down any prior Simulator instance bound to this host —
      // re-renders need a fresh mount, and the old buttons / pointer
      // interpreters would leak otherwise.
      this._detachSimFor(host);

      // Compose via the SDK exactly as `Baguette.use` does — we just
      // skip its definition fetch because farm-app has already cached
      // it. `_Simulator.mount` builds bezel + per-button overlays +
      // screen input + keyboard in a single call; nothing here for the
      // farm to reinvent.
      const B = window.Baguette;
      const transport = new B._Transport({
        send: (p) => this.session && this.session.send(p)
      });
      const sim = new B._Simulator(def, transport);
      sim.mount(host);
      // Graft the tile's live surface in place of the freshly-minted
      // canvas the bezel built, so the existing StreamSession keeps
      // painting where it already is.
      sim.canvas.replaceWith(element);
      // The grid tile is selectable; if we left the SDK's screen
      // input wired there, every click on the screen surface would
      // fire a tap to the device AND bubble up to the tile-select
      // handler. Detach screen input on hosts that opted out — the
      // bezel + per-button overlays stay clickable either way, and
      // the keyboard never auto-focuses without input enabled.
      if (!opts || !opts.input) {
        try { sim.screen.detach(); } catch {}
        if (sim.keyboard) { try { sim.keyboard.detach(); } catch {} }
      }
      element.style.cssText =
        `display:block;width:100%;height:100%;object-fit:${fitObject};background:#000`;

      // Bezel sets the wrapper inline to `display:inline-block;
      // max-height:70dvh` (sized for the single-device page). In the
      // farm grid the wrapper sits inside a fixed-height tile; without
      // explicit dimensions the image at `height:100%; width:auto`
      // overflows or letterboxes inside the column box, leaving
      // screenArea (% of wrapper) drifted from the real bezel cutout.
      //
      // Fix: size the wrapper in explicit pixels matching the bare
      // composite's aspect ratio. Compute a fit-inside box of
      // (host.width, host.height) that preserves the viewport ratio,
      // then pin wrapper.width/height to those numbers.
      const wrapper = sim._bezel.wrapper;
      const bezelImg = sim._bezel.frameImg;
      if (bezelImg) {
        bezelImg.style.maxHeight = '100%';
        bezelImg.style.maxWidth  = '100%';
      }
      if (wrapper && screenDef && screenDef.viewport &&
          screenDef.viewport.width && screenDef.viewport.height) {
        const ratio = screenDef.viewport.width / screenDef.viewport.height;
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

      this._sims = this._sims || new Map();
      this._sims.set(host, sim);
      host.dataset.bezelMounted = 'yes';
      host.dataset.activeKind = element.tagName;
      return;
    }
    // Raw mode entered — drop any sim bound to this host before
    // wiping the DOM (raw-mode branch below clears innerHTML).
    this._detachSimFor(host);

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

  // promote() / demote() now toggle stream quality only. Input is
  // wired by `Simulator.mount` inside `_mountIn` as soon as a bezel
  // is mounted on the focus host, so the user gets gestures +
  // keyboard automatically.
  FarmTile.prototype.promote = function () {
    if (!this.session) { this.start(); }
    this.mode = 'full';
    this.applyConfig(FULL);
  };

  FarmTile.prototype.demote = function () {
    if (!this.session) return;
    this.mode = 'thumb';
    this.applyConfig(THUMB);
    // The mirror element stays in DOM until FarmFocus.dispose() wipes
    // the focus pane innerHTML; either way, no point burning a rAF
    // loop when nothing's looking at the mirror.
    this._stopMirrorCopy();
  };

  // Detach the Simulator bound to a particular host, if any. Used by
  // `_mountIn` on every re-render so each mount gets a clean slate
  // (fresh bezel, fresh button overlays, fresh PointerInterpreter).
  FarmTile.prototype._detachSimFor = function (host) {
    const sim = this._sims.get(host);
    if (!sim) return;
    try { sim.detach(); } catch {}
    this._sims.delete(host);
  };

  // Forward sidebar buttons (home / lock / volume) to the device.
  // Any active sim shares the same transport sink (this.session.send),
  // so picking the first one is sufficient. No-op if no sim is mounted
  // (e.g. bezels-off mode with focus pane empty).
  FarmTile.prototype._anySim = function () {
    return this._sims.values().next().value || null;
  };
  FarmTile.prototype.button = function (name) {
    const sim = this._anySim();
    if (sim) sim.pressButton(name);
  };
  // Pinch-overlay container of whichever mounted sim still has its
  // PinchOverlay alive — the grid sim drops its overlay when input is
  // detached, so this surfaces the focus sim's overlay when focused.
  // Used by the BrowserRecorder to composite pinch dots into recordings.
  FarmTile.prototype.overlayContainer = function () {
    for (const sim of this._sims.values()) {
      const c = sim.pinchOverlayContainer;
      if (c) return c;
    }
    return null;
  };
  FarmTile.prototype.type = function (text) {
    const sim = this._anySim();
    if (sim) sim.type(text);
  };
  FarmTile.prototype.key = function (code) {
    const sim = this._anySim();
    if (sim && sim.keyboard) sim.keyboard.key(code);
  };

  FarmTile.prototype.applyConfig = function (cfg) {
    if (!this.session || !this.session.send) return;
    this.session.send({ type: 'set_fps',     fps: cfg.fps });
    this.session.send({ type: 'set_scale',   scale: cfg.scale });
    this.session.send({ type: 'set_bitrate', bps: cfg.bps });
  };

  FarmTile.prototype.forceIdr  = function () { this.session?.send?.({ type: 'force_idr' }); };
  FarmTile.prototype.snapshot  = function () { this.session?.send?.({ type: 'snapshot' }); };

  FarmTile.prototype.stop = function () {
    // Detach every mounted Simulator (bezel + buttons + screen +
    // keyboard) before tearing down the stream.
    for (const sim of this._sims.values()) {
      try { sim.detach(); } catch {}
    }
    this._sims.clear();
    this._stopMirrorCopy();
    if (this._fitObserver) { this._fitObserver.disconnect(); this._fitObserver = null; }
    if (this.session) { this.session.stop(); this.session = null; }
    this.mode = 'idle';
    if (this.canvas.parentElement) this.canvas.parentElement.removeChild(this.canvas);
    if (this.mirror.parentElement) this.mirror.parentElement.removeChild(this.mirror);
  };

  window.FarmTile = FarmTile;
})();
