const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const html = fs.readFileSync(path.join(__dirname, '../../scripts/bench-live-view/www/bench.html'), 'utf8');
const script = html.match(/<script>([\s\S]*?)<\/script>/)[1];

function bench(search, { browserClock = performance, fetchClock } = {}) {
  const posts = [], sends = [];
  const load = new Function('location', 'document', 'OffscreenCanvas', 'window', 'WebSocket', 'performance', 'fetch',
    script.replace(/^run\(\)\.catch.*$/m, 'return { tap, state: window.__bench, calibrateClock, freezeSummary, freezes: measureFreezes };'));
  const result = load({ search, origin: 'http://localhost:8777' }, { getElementById: () => ({}) },
    class { getContext() { return {}; } }, {}, { OPEN: 1 }, browserClock, (url, request) => {
      if (url === 'clock' && fetchClock) return fetchClock();
      posts.push({ url, request });
      return Promise.resolve();
    });
  const socket = { readyState: 1, send: line => sends.push(JSON.parse(line)) };
  return { ...result, socket, sends, posts };
}

test('should fail a baguette tap run when its input WebSocket is unavailable', () => {
  const { tap, state, socket, sends, posts } = bench('?transport=webrtc&udid=test');
  assert.throws(() => tap('left'), /input WebSocket/);
  state.taps = socket;
  tap('left');
  socket.readyState = 3;

  assert.throws(() => tap('right'), /input WebSocket/);
  assert.equal(sends.length, 1);
  assert.equal(posts.length, 0);
  assert.equal(state.tapPath, 'socket');
});

for (const endpoint of ['/pion/whep', '/whep']) {
  test(`should post the taps for the ${endpoint} reference`, () => {
    const { tap, state, posts } = bench(`?transport=webrtc&udid=test&whep=${endpoint}`);
    tap('left');

    assert.equal(posts[0].url, 'http://localhost:8777/api/devices/test/input');
    assert.equal(posts[0].request.method, 'POST');
    assert.equal(state.tapPath, 'POST /input');
  });
}

test('should report each picture stall and count how long the picture stayed frozen', () => {
  const { freezes } = bench('?transport=webrtc&udid=test');
  const origin = 1_700_000_000_000;
  const result = freezes([0, 100, 300, 550, 600, 1_500, 2_400], 100, 2_000, origin);

  assert.deepEqual(result.freezes, [
    { startedAtMs: origin + 300, recoveredAtMs: origin + 550, durationMs: 250 },
    { startedAtMs: origin + 600, recoveredAtMs: origin + 1_500, durationMs: 900 },
    { startedAtMs: origin + 1_500, recoveredAtMs: null, durationMs: 500 },
  ]);
  assert.equal(result.totalFreezeMs, 1_650);
});

test('should put stalls on the viewer clock using the shortest successful round trip', async () => {
  const epoch = 1_700_000_000_000;
  const times = [0, 100, 100, 100, 180, 120, 110];
  const replies = [epoch + 140, epoch + 110, null];
  const { calibrateClock, freezeSummary, state } = bench('?transport=webrtc&udid=test', {
    browserClock: { now: () => times.shift(), timeOrigin: epoch - 500 },
    fetchClock: async () => {
      const stamp = replies.shift();
      return { ok: stamp !== null, headers: { get: () => stamp === null ? null : String(stamp) } };
    },
  });
  state.viewerID = 'test-viewer';
  state.clock = await calibrateClock();
  state.frames = [500];

  const result = freezeSummary(200, 500);
  assert.equal(result.viewerID, 'test-viewer');
  assert.equal(result.freezeClock, 'server');
  assert.equal(result.clockUncertaintyMs, 11);
  assert.deepEqual(result.freezes, [{ startedAtMs: epoch + 200, recoveredAtMs: epoch + 500, durationMs: 300 }]);
});
