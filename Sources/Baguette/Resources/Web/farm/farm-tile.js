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
    this.session = null;
    this.mode = 'idle';   // 'idle' | 'thumb' | 'full'
    this.lastFps = 0;
  }

  // Move the canvas into whichever screen-host element the latest view
  // produced for this udid. If the device is not booted, we leave the
  // host empty — its overlay (BOOTING / SHUTDOWN / etc.) shows through.
  //
  // `opts.useBezel` swaps the wrapper: when true, the existing
  // DeviceFrame builds the bezel <img> + screenArea + a fresh canvas;
  // we discard that canvas and graft `this.canvas` (the live decoder
  // target) into the screenArea so the WebSocket isn't disturbed.
  // When false, the canvas sits raw inside the host and edge-fills it.
  FarmTile.prototype.attach = function (host, opts) {
    if (!host) return;
    const useBezel = !!(opts && opts.useBezel && window.DeviceFrame);
    const layout = opts && opts.layout || null;

    if (useBezel) {
      // Only rebuild the bezel chrome when the host or mode changed.
      // Idempotent re-attach lets renderAll() run without thrashing.
      if (host.dataset.bezelMounted === 'yes' && this.canvas.parentElement?.parentElement === host.firstChild) {
        return;
      }
      host.classList.add('with-bezel');
      const frame = new window.DeviceFrame({ udid: this.udid, layout });
      const surface = frame.mount(host);
      // DeviceFrame creates its own canvas — replace it with ours.
      surface.canvas.replaceWith(this.canvas);
      this.canvas.style.cssText =
        'display:block;width:100%;height:100%;object-fit:fill;background:#000';
      host.dataset.bezelMounted = 'yes';
      return;
    }

    // Raw mode — strip any prior bezel scaffolding, drop the canvas in.
    if (host.dataset.bezelMounted === 'yes') {
      host.innerHTML = '';
      delete host.dataset.bezelMounted;
      host.classList.remove('with-bezel');
    }
    this.canvas.style.cssText =
      'position:absolute;inset:0;width:100%;height:100%;object-fit:contain;background:#000';
    if (this.canvas.parentElement !== host) host.appendChild(this.canvas);
  };

  FarmTile.prototype.start = function () {
    if (this.session || this.device.uiState !== 'live') return;
    this.session = new window.StreamSession({
      udid:   this.udid,
      format: 'mjpeg',           // MJPEG decodes anywhere — H.264/AVCC needs WebCodecs.
      version: 'v2',
      canvas: this.canvas,
      onSize: (w, h) => this.onSize(this.udid, w, h),
      onFps:  (fps) => {
        this.lastFps = fps;
        this.onTelemetry(this.udid, { fps });
      },
      onLog:  () => {}
    });
    this.session.start();
    this.mode = 'thumb';
    // ReconfigParser needs the socket open — give it a tick. start()
    // sets onopen; we ride it via a microtask so the apply lands on
    // an OPEN socket rather than a queued one.
    setTimeout(() => this.applyConfig(THUMB), 200);
  };

  FarmTile.prototype.promote = function () {
    if (!this.session) { this.start(); }
    this.mode = 'full';
    this.applyConfig(FULL);
  };

  FarmTile.prototype.demote = function () {
    if (!this.session) return;
    this.mode = 'thumb';
    this.applyConfig(THUMB);
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
    if (this.session) { this.session.stop(); this.session = null; }
    this.mode = 'idle';
    if (this.canvas.parentElement) this.canvas.parentElement.removeChild(this.canvas);
  };

  window.FarmTile = FarmTile;
})();
