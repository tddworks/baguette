// WhepSession — the phone plane over WebRTC (WHEP, draft-ietf-wish-whep), with the same
// face as StreamSession (start / stop / send), so the page swaps one for the
// other by format. The picture arrives as H.265 when the browser offers it, else H.264 (`codec:` picks), in a hidden <video> and is
// painted onto the session's canvas frame by frame, so everything that reads
// the canvas (recording, the inspector, sizing) keeps working. Input and
// stream control ride the viewer's control socket, as they ride the stream
// socket for StreamSession. The server owns the rules; this is a dumb pipe.
//
//   const session = new WhepSession({ udid, canvas, display,
//     onSize, onFps, onLog, onText, onOpen, onClose, onError, onPaint });
//   await session.start();
//   session.send({ type: 'tap', … });
//   session.stop();
//
// Design: docs/features/webrtc/design.md.
(function () {
  'use strict';

  function WhepSession(opts) {
    this.opts = opts;
    this.peer = null;
    this.socket = null;
    this.video = null;
    this.location = null;
    this.alive = false;
    this.frameCount = 0;
    this.fpsTimer = null;
  }

  /** The device's WHEP route, as the page's tree spells it, with the display
   *  plane, the congestion control (`transport-cc`, `remb`, `off`) and the
   *  codec (`h265`, `h264`, `auto`) asked for. */
  WhepSession.whepPath = function (udid, display, congestion, codec) {
    const base = (window.BaguetteTarget && window.BaguetteTarget.base) || 'simulators';
    const params = [];
    if (display === 'phone' || display === 'carplay') params.push('display=' + encodeURIComponent(display));
    if (congestion) params.push('congestion=' + encodeURIComponent(congestion));
    if (codec) params.push('codec=' + encodeURIComponent(codec));
    return '/' + base + '/' + encodeURIComponent(udid) + '/whep' + (params.length ? '?' + params.join('&') : '');
  };

  /** The viewer's control socket, next to the resource the server named. */
  WhepSession.controlUrl = function (location) {
    const proto = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
    return proto + '//' + window.location.host + location + '/control';
  };

  WhepSession.prototype.send = function () { return false; };

  /** The ICE servers the server says its browser should use; none when it names none or can't say. */
  WhepSession.iceServers = async function () {
    try {
      const response = await window.fetch('/webrtc/ice-servers', { method: 'GET' });
      if (!response.ok) return [];
      return JSON.parse(await response.text()).iceServers || [];
    } catch (_) { return []; }
  };

  /** Until the browser has gathered its candidates — at most `ms`: then the offer goes with what it has. */
  WhepSession.gathered = function (peer, ms) {
    return new Promise((resolve) => {
      if (peer.iceGatheringState === 'complete') return resolve();
      peer.onicegatheringstatechange = () => { if (peer.iceGatheringState === 'complete') resolve(); };
      window.setTimeout(resolve, ms);
    });
  };

  WhepSession.prototype.start = async function () {
    const { udid, canvas, display, congestion, onSize, onFps, onLog, onText, onOpen, onError, onPaint } = this.opts;
    const log = onLog || (() => {});
    // H.265 when the browser offers it, H.264 otherwise (`auto`, the default
    // since slice 6 measured it costing nothing); `codec: 'h264'` opts out.
    const codec = this.opts.codec || 'auto';
    this.alive = true;

    // Its STUN servers first: the browser gathers its own public address with
    // them, and the offer carries it, so the server can check it (full ICE).
    const iceServers = await WhepSession.iceServers();
    const peer = new window.RTCPeerConnection({ bundlePolicy: 'max-bundle', iceServers });
    this.peer = peer;
    const transceiver = peer.addTransceiver('video', { direction: 'recvonly' });
    try {
      // H.264 first — or H.265, then H.264, when H.265 was asked for; the server chooses.
      const codecs = window.RTCRtpReceiver.getCapabilities('video').codecs;
      const named = (type) => codecs.filter((c) => c.mimeType.toLowerCase() === type);
      const first = (codec === 'h265' || codec === 'auto' ? named('video/h265') : []).concat(named('video/h264'));
      transceiver.setCodecPreferences(first.concat(codecs.filter((c) => first.indexOf(c) < 0)));
    } catch (_) { /* the browser picks; the server answers what it can send or refuses */ }

    // Hidden but in the document: some browsers won't decode a detached video.
    const video = window.document.createElement('video');
    video.muted = true;
    video.autoplay = true;
    video.playsInline = true;
    video.setAttribute('playsinline', '');
    video.style.cssText = 'position:fixed;width:1px;height:1px;opacity:0;pointer-events:none;left:0;top:0';
    window.document.body.appendChild(video);
    this.video = video;
    peer.ontrack = (e) => {
      // Latency over smoothness: show each frame as soon as it decodes.
      if (e.receiver) {
        e.receiver.jitterBufferTarget = 0;
        if ('playoutDelayHint' in e.receiver) e.receiver.playoutDelayHint = 0;
      }
      video.srcObject = e.streams[0];
    };

    const ctx = canvas.getContext('2d');
    const paint = (_, meta) => {
      if (!this.alive) return;
      const w = meta.width, h = meta.height;
      if (canvas.width !== w || canvas.height !== h) {
        canvas.width = w;
        canvas.height = h;
        if (onSize) onSize(w, h);
      }
      ctx.drawImage(video, 0, 0);
      this.frameCount++;
      if (onPaint) onPaint(w, h);
      video.requestVideoFrameCallback(paint);
    };
    video.requestVideoFrameCallback(paint);
    this.fpsTimer = window.setInterval(() => {
      if (onFps) onFps(this.frameCount);
      this.frameCount = 0;
    }, 1000);

    const offer = await peer.createOffer();
    await peer.setLocalDescription(offer);
    await WhepSession.gathered(peer, 2000);
    const response = await window.fetch(WhepSession.whepPath(udid, display, congestion, codec), {
      method: 'POST', headers: { 'Content-Type': 'application/sdp' },
      body: (peer.localDescription || offer).sdp,
    });
    const body = await response.text();
    if (!this.alive) return;
    if (!response.ok) {
      let reason = body;
      try { reason = JSON.parse(body).error || body; } catch (_) { /* plain text */ }
      log('WebRTC refused (' + response.status + '): ' + reason, true);
      if (onError) onError();
      return;
    }
    this.location = response.headers.get('Location');
    await peer.setRemoteDescription({ type: 'answer', sdp: body });

    const socket = new window.WebSocket(WhepSession.controlUrl(this.location));
    this.socket = socket;
    this.send = (payload) => {
      if (socket.readyState !== window.WebSocket.OPEN) return false;
      socket.send(JSON.stringify(payload));
      return true;
    };
    socket.onopen = () => {
      log('WebRTC viewer ' + this.location);
      if (onOpen) onOpen();
    };
    socket.onmessage = (e) => {
      if (typeof e.data !== 'string' || !onText) return;
      try { onText(JSON.parse(e.data)); } catch (_) { /* not JSON */ }
    };
  };

  WhepSession.prototype.stop = function () {
    if (!this.alive) return;
    this.alive = false;
    this.send = () => false;
    if (this.fpsTimer) { window.clearInterval(this.fpsTimer); this.fpsTimer = null; }
    if (this.location) {
      window.fetch(this.location, { method: 'DELETE' }).catch(() => {});
    }
    if (this.socket) { try { this.socket.close(); } catch (_) {} this.socket = null; }
    if (this.peer) { try { this.peer.close(); } catch (_) {} }
    if (this.video) { this.video.remove(); this.video = null; }
    if (this.opts.onClose) this.opts.onClose();
  };

  window.WhepSession = WhepSession;
})();
