// StreamSession — owns the WebSocket + paint loop for one running
// stream. Decode strategy is delegated to FrameDecoder; canvas
// painting is a single-frame queue drained on requestAnimationFrame
// (latest wins; older frames are released).
//
//   const session = new StreamSession({
//     udid, format, version,
//     display,               // optional 'phone' | 'carplay'
//     url,                    // optional custom stream WebSocket URL
//     canvas,
//     onSize: (w, h) => …,    // first frame + on resize
//     onFps:  (fps) => …,     // every second
//     onLog:  (msg, isErr) => …,
//     onOpen, onClose, onError, onPaint,
//   });
//   session.start();
//   // …
//   session.stop();
//
// Doesn't know what a sidebar button is, doesn't touch the gallery,
// doesn't manage input. Owns precisely the WS + paint pipeline.
(function () {
  'use strict';

  function StreamSession(opts) {
    this.opts = opts;
    this.ws = null;
    this.decoder = null;
    this.alive = false;
    this.pending = null;
    this.frameCount = 0;
    this.fpsTimer = null;
    this.rafId = null;
  }

  StreamSession.prototype.start = function () {
    const {
      udid, format, version, canvas, url, display,
      onSize, onFps, onLog, onText, onOpen, onClose, onError, onPaint,
    } = this.opts;
    const ctx = canvas.getContext('2d');
    const log = onLog || (() => {});

    const wsUrl = url || buildWSUrl(udid, format, version || 'v2', display);
    const socket = new WebSocket(wsUrl);
    socket.binaryType = 'arraybuffer';
    this.ws = socket;
    this.alive = true;

    // Upstream transport: input + control rides on the same socket.
    // Callers grab `session.send` and pass it to SimInput as its
    // `transport`. Drops messages when the socket isn't ready —
    // gestures fired before the open handshake are rare and not
    // worth queuing.
    this.send = (payload) => {
      if (socket.readyState === WebSocket.OPEN) {
        socket.send(JSON.stringify(payload));
        return true;
      }
      return false;
    };

    this.decoder = window.FrameDecoder.create(format, {
      onFrame: (frame) => {
        if (this.pending && typeof this.pending.close === 'function') {
          try { this.pending.close(); } catch {}
        }
        this.pending = frame;
      },
      onLog: log,
    });

    socket.onopen    = () => {
      log('WS connected');
      if (onOpen) onOpen();
    };
    // Text frames piggyback alongside binary video on the same WS
    // (describe_ui_result, server-pushed errors, …). Give callers
    // first crack at parsed JSON; if their hook returns truthy the
    // decoder doesn't get the frame. Binary always falls through.
    socket.onmessage = (e) => {
      if (onText && !(e.data instanceof ArrayBuffer)) {
        let env = null;
        try { env = JSON.parse(e.data); } catch { /* not JSON; let decoder log */ }
        if (env && onText(env) === true) return;
      }
      this.decoder.feed(e);
    };
    socket.onclose   = () => {
      log('WS disconnected');
      this.alive = false;
      this.ws = null;
      if (onClose) onClose();
    };
    socket.onerror   = () => {
      log('WS error', true);
      if (onError) onError();
    };

    const paint = () => {
      if (!this.alive) return;
      if (this.pending) {
        const f = this.pending;
        this.pending = null;
        const w = f.displayWidth || f.width;
        const h = f.displayHeight || f.height;
        if (canvas.width !== w || canvas.height !== h) {
          canvas.width = w;
          canvas.height = h;
          if (onSize) onSize(w, h);
        }
        ctx.drawImage(f, 0, 0);
        if (typeof f.close === 'function') { try { f.close(); } catch {} }
        this.frameCount++;
        if (onPaint) onPaint(w, h);
      }
      this.rafId = requestAnimationFrame(paint);
    };
    this.rafId = requestAnimationFrame(paint);

    this.fpsTimer = setInterval(() => {
      if (onFps) onFps(this.frameCount);
      this.frameCount = 0;
    }, 1000);
  };

  StreamSession.prototype.stop = function () {
    this.alive = false;
    if (this.fpsTimer) { clearInterval(this.fpsTimer); this.fpsTimer = null; }
    if (this.rafId)    { cancelAnimationFrame(this.rafId); this.rafId = null; }
    if (this.ws)       { try { this.ws.close(); } catch {} this.ws = null; }
    if (this.decoder)  { this.decoder.dispose(); this.decoder = null; }
    if (this.pending && typeof this.pending.close === 'function') {
      try { this.pending.close(); } catch {}
    }
    this.pending = null;
  };

  function buildWSUrl(udid, format, version, display) {
    const loc = window.location;
    const proto = loc.protocol === 'https:' ? 'wss:' : 'ws:';
    // BaguetteTarget switches the base for /devices/:udid pages; the
    // fallback keeps embedders that load this file standalone working.
    const base = (window.BaguetteTarget && window.BaguetteTarget.base) || 'simulators';
    let url = `${proto}//${loc.host}/${base}/${encodeURIComponent(udid)}/stream`
         + `?format=${encodeURIComponent(format)}`
         + `&version=${encodeURIComponent(version)}`;
    if (display === 'phone' || display === 'carplay') {
      url += `&display=${encodeURIComponent(display)}`;
    }
    return url;
  }

  StreamSession.buildWSUrl = buildWSUrl;
  window.StreamSession = StreamSession;
})();
