'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { loadBrowserModules } = require('./helpers/load-browser-module.js');

const MODULE_PATH = path.join(
  __dirname, '..', '..', 'Sources', 'Baguette', 'Resources', 'Web', 'whep-session.js'
);

/** A browser just big enough for a WHEP session: what it posted, opened and drew. */
function fakeBrowser({
  status = 201, answer = 'v=0\r\nanswer\r\n', location = '/devices/U/whep/v1',
  iceServers = [], gathering = 'complete',
} = {}) {
  const seen = { requests: [], sockets: [], drawn: [], appended: [], removed: 0, closedPeers: 0, timers: [] };
  const frameCallbacks = [];
  const video = {
    style: {},
    setAttribute() {},
    requestVideoFrameCallback(cb) { frameCallbacks.push(cb); },
    remove() { seen.removed += 1; },
  };
  class FakeSocket {
    constructor(url) {
      this.url = url;
      this.readyState = 0;
      this.sent = [];
      seen.sockets.push(this);
    }
    send(text) { this.sent.push(text); }
    close() { this.readyState = 3; }
    open() { this.readyState = 1; if (this.onopen) this.onopen(); }
  }
  FakeSocket.OPEN = 1;
  class FakePeer {
    constructor(config) { this.config = config; this.iceGatheringState = gathering; }
    get localDescription() { return this.local && { type: 'offer', sdp: this.local.sdp + (this.gathered || '') }; }
    /** The browser finishing its gathering: one candidate more, then complete. */
    finishGathering() {
      this.gathered = 'a=candidate:1 1 udp 2122260223 192.168.1.20 54400 typ host\r\n';
      this.iceGatheringState = 'complete';
      if (this.onicegatheringstatechange) this.onicegatheringstatechange();
    }
    addTransceiver(kind, init) { this.transceiver = { kind, init, setCodecPreferences(c) { this.codecs = c; } }; return this.transceiver; }
    async createOffer() { return { type: 'offer', sdp: 'v=0\r\noffer\r\n' }; }
    async setLocalDescription(d) { this.local = d; }
    async setRemoteDescription(d) { this.remote = d; }
    close() { seen.closedPeers += 1; }
  }
  const window = {
    location: { protocol: 'http:', host: 'localhost:8421' },
    BaguetteTarget: { base: 'devices' },
    WebSocket: FakeSocket,
    RTCPeerConnection: FakePeer,
    RTCRtpReceiver: { getCapabilities: () => ({ codecs: [{ mimeType: 'video/VP8' }, { mimeType: 'video/H264' }, { mimeType: 'video/H265' }] }) },
    document: {
      createElement: () => video,
      body: { appendChild(node) { seen.appended.push(node); } },
    },
    setInterval: () => 1,
    setTimeout: (fn, ms) => { seen.timers.push({ fn, ms }); return seen.timers.length; },
    clearInterval: () => {},
    async fetch(url, init) {
      seen.requests.push({ url, method: init.method, body: init.body, type: init.headers && init.headers['Content-Type'] });
      if (url === '/webrtc/ice-servers') {
        return { ok: true, status: 200, headers: { get: () => null }, async text() { return JSON.stringify({ iceServers }); } };
      }
      return {
        ok: status >= 200 && status < 300,
        status,
        headers: { get: (name) => (name.toLowerCase() === 'location' ? location : null) },
        async text() { return status === 201 ? answer : '{"ok":false,"error":"the offer has no video"}'; },
      };
    },
  };
  const canvas = {
    width: 0, height: 0,
    getContext: () => ({ drawImage: (source, x, y) => seen.drawn.push({ source, x, y }) }),
  };
  return { window, canvas, video, seen, frameCallbacks };
}

function session(browser, extra) {
  const { WhepSession } = loadBrowserModules([MODULE_PATH], browser.window);
  return new WhepSession(Object.assign({ udid: 'U', canvas: browser.canvas }, extra || {}));
}

test('should post its offer to the device\'s WHEP route and take the answer', async () => {
  const browser = fakeBrowser();
  const whep = session(browser);

  await whep.start();

  assert.deepEqual(browser.seen.requests.find((r) => r.method === 'POST'),
    { url: '/devices/U/whep', method: 'POST', body: 'v=0\r\noffer\r\n', type: 'application/sdp' });
  assert.equal(whep.peer.remote.sdp, 'v=0\r\nanswer\r\n');
  assert.equal(whep.peer.transceiver.init.direction, 'recvonly');
  assert.deepEqual(whep.peer.transceiver.codecs.map((c) => c.mimeType), ['video/H264', 'video/VP8', 'video/H265']);
});

test('should send input over the viewer\'s control socket once it is open', async () => {
  const browser = fakeBrowser();
  const opened = [];
  const whep = session(browser, { onOpen: () => opened.push(true) });

  await whep.start();
  const socket = browser.seen.sockets[0];
  assert.equal(socket.url, 'ws://localhost:8421/devices/U/whep/v1/control');
  assert.equal(whep.send({ type: 'tap', x: 1, y: 2 }), false);   // not open yet
  socket.open();

  assert.equal(whep.send({ type: 'tap', x: 1, y: 2 }), true);
  assert.deepEqual(socket.sent, ['{"type":"tap","x":1,"y":2}']);
  assert.deepEqual(opened, [true]);
});

test('should hand the page what its control socket says', async () => {
  const browser = fakeBrowser();
  const heard = [];
  const whep = session(browser, { onText: (env) => heard.push(env) });

  await whep.start();
  browser.seen.sockets[0].onmessage({ data: '{"type":"describe_ui_result","ok":true}' });

  assert.deepEqual(heard, [{ type: 'describe_ui_result', ok: true }]);
});

test('should paint each presented frame onto its canvas, sized to the video', async () => {
  const browser = fakeBrowser();
  const sizes = [];
  const whep = session(browser, { onSize: (w, h) => sizes.push([w, h]) });

  await whep.start();
  browser.frameCallbacks.shift()(0, { width: 1206, height: 2622 });
  browser.frameCallbacks.shift()(16, { width: 1206, height: 2622 });

  assert.deepEqual(sizes, [[1206, 2622]]);
  assert.equal(browser.canvas.width, 1206);
  assert.equal(browser.seen.drawn.length, 2);
  assert.equal(browser.seen.drawn[0].source, browser.video);
});

test('should say why when the server refuses the offer', async () => {
  const browser = fakeBrowser({ status: 422 });
  const logged = [];
  const errors = [];
  const whep = session(browser, { onLog: (msg, isErr) => logged.push([msg, isErr]), onError: () => errors.push(true) });

  await whep.start();

  assert.deepEqual(logged.at(-1), ['WebRTC refused (422): the offer has no video', true]);
  assert.deepEqual(errors, [true]);
  assert.equal(browser.seen.sockets.length, 0);
});

test('should ask for the display it was given', async () => {
  const browser = fakeBrowser();
  const whep = session(browser, { display: 'phone' });

  await whep.start();

  assert.equal(browser.seen.requests.find((r) => r.method === 'POST').url, '/devices/U/whep?display=phone');
});

test('should ask for the congestion control it was given, beside the display', async () => {
  const browser = fakeBrowser();
  const whep = session(browser, { display: 'phone', congestion: 'remb' });

  await whep.start();

  assert.equal(browser.seen.requests.find((r) => r.method === 'POST').url, '/devices/U/whep?display=phone&congestion=remb');
});

test('should ask for the codec it was given, beside the display', async () => {
  const browser = fakeBrowser();
  const whep = session(browser, { display: 'phone', codec: 'h265' });

  await whep.start();

  assert.equal(browser.seen.requests.find((r) => r.method === 'POST').url, '/devices/U/whep?display=phone&codec=h265');
});

test('should prefer H.265, then H.264, when it was given h265', async () => {
  const browser = fakeBrowser();
  const whep = session(browser, { codec: 'h265' });

  await whep.start();

  assert.deepEqual(whep.peer.transceiver.codecs.map((c) => c.mimeType), ['video/H265', 'video/H264', 'video/VP8']);
});

test('should hang up when stopped, closing its socket, peer and video', async () => {
  const browser = fakeBrowser();
  const closed = [];
  const whep = session(browser, { onClose: () => closed.push(true) });
  await whep.start();

  whep.stop();
  whep.stop();

  assert.deepEqual(browser.seen.requests.filter((r) => r.method === 'DELETE').map((r) => [r.method, r.url]), [['DELETE', '/devices/U/whep/v1']]);
  assert.equal(browser.seen.sockets[0].readyState, 3);
  assert.equal(browser.seen.closedPeers, 1);
  assert.equal(browser.seen.removed, 1);
  assert.deepEqual(closed, [true]);
  assert.equal(whep.send({ type: 'tap' }), false);
});

test('should give its peer the ICE servers the server names, asked before its offer', async () => {
  const browser = fakeBrowser({ iceServers: [{ urls: 'stun:stun.example.com:3478' }] });
  const whep = session(browser);

  await whep.start();

  assert.equal(browser.seen.requests[0].url, '/webrtc/ice-servers');
  assert.deepEqual(whep.peer.config.iceServers, [{ urls: 'stun:stun.example.com:3478' }]);
  assert.equal(whep.peer.config.bundlePolicy, 'max-bundle');
});

test('should post its offer with the candidates its browser gathered', async () => {
  const browser = fakeBrowser({ gathering: 'gathering' });
  const whep = session(browser);

  const started = whep.start();
  await new Promise((resolve) => setImmediate(resolve));
  whep.peer.finishGathering();
  await started;

  const post = browser.seen.requests.find((r) => r.method === 'POST');
  assert.match(post.body, /a=candidate:1 1 udp 2122260223 192\.168\.1\.20 54400 typ host/);
});

test("should post its offer anyway when gathering doesn't finish within two seconds", async () => {
  const browser = fakeBrowser({ gathering: 'gathering' });
  const whep = session(browser);

  const started = whep.start();
  await new Promise((resolve) => setImmediate(resolve));
  const wait = browser.seen.timers.find((t) => t.ms === 2000);
  assert.ok(wait, 'a bounded wait for gathering');
  wait.fn();
  await started;

  assert.ok(browser.seen.requests.some((r) => r.method === 'POST'));
});

test("should still start without ICE servers when the server names none or can't be asked", async () => {
  const browser = fakeBrowser();
  const whep = session(browser);

  await whep.start();

  assert.deepEqual(whep.peer.config.iceServers, []);
});
