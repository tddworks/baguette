// whep-overlay.js — injected by proxy.mjs into baguette serve's device page when it is opened with
// ?transport=webrtc. The page stays baguette's own: its StreamSession, its touch / scroll / toolbar input.
// Only the picture changes: a WHEP <video> sits exactly over the stream canvas, with pointer-events off so
// every touch still lands on the page's own input layer, and the page's WebSocket stream is throttled to
// 2 fps so it doesn't compete with WebRTC for bandwidth (it still carries the gestures).
(function () {
  'use strict';
  const STREAM_FPS = 2;
  const badge = document.createElement('div');
  badge.style.cssText = 'position:fixed;left:8px;bottom:8px;z-index:2147483647;padding:4px 8px;border-radius:6px;'
    + 'font:12px -apple-system,system-ui,sans-serif;background:rgba(20,80,40,.85);color:#dfd;pointer-events:none';
  const say = (text) => { badge.textContent = 'WebRTC · ' + text; if (!badge.isConnected && document.body) document.body.appendChild(badge); };

  let current = null;   // { video, pc, canvas, timer }

  function teardown() {
    if (!current) return;
    clearInterval(current.timer);
    try { current.pc.close(); } catch (_) {}
    current.video.remove();
    current = null;
  }

  // Keep the video glued to the canvas: same box, same rounding, same transform, inside the same parent.
  function follow(video, canvas) {
    const parent = canvas.parentElement;
    if (!parent) return;
    if (video.parentElement !== parent) parent.insertBefore(video, canvas.nextSibling);
    if (getComputedStyle(parent).position === 'static') parent.style.position = 'relative';
    const cs = getComputedStyle(canvas);
    Object.assign(video.style, {
      left: canvas.offsetLeft + 'px', top: canvas.offsetTop + 'px',
      width: canvas.offsetWidth + 'px', height: canvas.offsetHeight + 'px',
      borderRadius: cs.borderRadius, transform: cs.transform === 'none' ? '' : cs.transform,
      transformOrigin: cs.transformOrigin, clipPath: cs.clipPath === 'none' ? '' : cs.clipPath,
    });
  }

  async function play(canvas) {
    teardown();
    const video = document.createElement('video');
    video.autoplay = true; video.muted = true; video.playsInline = true;
    video.setAttribute('playsinline', '');
    video.style.cssText = 'position:absolute;object-fit:fill;pointer-events:none;background:transparent;z-index:1';
    const pc = new RTCPeerConnection({ bundlePolicy: 'max-bundle' });
    current = { video, pc, canvas, timer: setInterval(() => follow(video, canvas), 250) };
    follow(video, canvas);

    say('starting the WHEP source…');
    await fetch('/bench/bridge/on', { method: 'POST' });

    const tr = pc.addTransceiver('video', { direction: 'recvonly' });
    try {
      const caps = RTCRtpReceiver.getCapabilities('video').codecs;
      const h264 = caps.filter(c => c.mimeType.toLowerCase() === 'video/h264');
      tr.setCodecPreferences([...h264, ...caps.filter(c => !h264.includes(c))]);
    } catch (_) {}
    pc.ontrack = (e) => {
      e.receiver.jitterBufferTarget = 0;
      if ('playoutDelayHint' in e.receiver) e.receiver.playoutDelayHint = 0;
      video.srcObject = e.streams[0];
    };
    pc.onconnectionstatechange = () => say(pc.connectionState);
    const offer = await pc.createOffer();
    await pc.setLocalDescription(offer);

    // MediaMTX answers 404 until the source is publishing: retry for up to 20 s.
    let answer = null;
    for (let i = 0; i < 40 && current && current.pc === pc; i++) {
      const res = await fetch('/whep', { method: 'POST', headers: { 'Content-Type': 'application/sdp' }, body: offer.sdp });
      if (res.ok) { answer = await res.text(); break; }
      await new Promise(r => setTimeout(r, 500));
    }
    if (!answer) { say('WHEP source never came up'); return; }
    answer = answer.replace(/a=rtcp-fb:\d+ goog-remb\r?\n/g, '');
    if (!answer.includes('b=AS:')) answer = answer.replace(/(c=IN\s+\S+\s+\S+\r?\n)/, '$1b=AS:15000\r\n');
    await pc.setRemoteDescription({ type: 'answer', sdp: answer });

    // Show presented fps so the two transports can be compared by eye.
    let frames = 0;
    const tick = () => { frames++; if (current && current.video === video) video.requestVideoFrameCallback(tick); };
    if ('requestVideoFrameCallback' in video) video.requestVideoFrameCallback(tick);
    const fps = setInterval(() => {
      if (!current || current.video !== video) return clearInterval(fps);
      say(pc.connectionState + ' · ' + frames + ' fps'); frames = 0;
    }, 1000);
  }

  // Hook StreamSession once its script has loaded: the phone's main session (not CarPlay / watch / 3D) gets
  // the overlay; its socket keeps carrying input and is held at STREAM_FPS.
  function hook(S) {
    if (!S || S.prototype.__whep) return;
    const start = S.prototype.start, stop = S.prototype.stop;
    S.prototype.__whep = true;
    S.prototype.start = function () {
      const out = start.apply(this, arguments);
      const o = this.opts || {};
      if (o.canvas && (!o.display || o.display === 'phone')) {
        const send = this.send;
        if (typeof send === 'function') {
          this.send = (p) => send(p && p.type === 'set_fps' ? Object.assign({}, p, { fps: STREAM_FPS }) : p);
        }
        if (this.ws) this.ws.addEventListener('open', () => this.ws.send(JSON.stringify({ type: 'set_fps', fps: STREAM_FPS })));
        this.__whepOwner = true;
        play(o.canvas).catch((e) => say('failed: ' + e.message));
      }
      return out;
    };
    S.prototype.stop = function () {
      if (this.__whepOwner && current && current.canvas === (this.opts || {}).canvas) teardown();
      return stop.apply(this, arguments);
    };
  }
  // This script runs first (injected right after <head>). stream-session.js later does
  // `window.StreamSession = StreamSession`; the setter hooks it before any page code can start a session.
  let S = window.StreamSession;
  hook(S);
  Object.defineProperty(window, 'StreamSession', {
    configurable: true,
    get: () => S,
    set: (v) => { S = v; hook(v); },
  });
  window.addEventListener('pagehide', () => { teardown(); navigator.sendBeacon && navigator.sendBeacon('/bench/bridge/off'); });
})();
