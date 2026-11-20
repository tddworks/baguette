const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const html = fs.readFileSync(path.join(__dirname, '../../scripts/bench-live-view/www/bench.html'), 'utf8');
const script = html.match(/<script>([\s\S]*?)<\/script>/)[1];

function bench(search) {
  const posts = [], sends = [];
  const load = new Function('location', 'document', 'OffscreenCanvas', 'window', 'WebSocket', 'fetch',
    script.replace(/^run\(\)\.catch.*$/m, 'return { tap, state: window.__bench };'));
  const result = load({ search, origin: 'http://localhost:8777' }, { getElementById: () => ({}) },
    class { getContext() { return {}; } }, {}, { OPEN: 1 }, (url, request) => {
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
